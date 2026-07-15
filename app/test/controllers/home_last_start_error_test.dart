// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/services/debug/serializers/home_state.dart';
import 'package:lxbox/services/haptic_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tempRoot);
  final String tempRoot;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempRoot;
  @override
  Future<String?> getApplicationSupportPath() async => tempRoot;
}

/// §250 — `HomeState.lastStartError`/`lastStartErrorAt`: диагностический дубль
/// `lastError` для Debug API. Прогоняем статус-события через реальный
/// `_handleStatusEvent` (мост `debugHandleStatusEvent`) и проверяем контракт:
/// пишется при аварийном stop/revoke, переживает UI-consume (`clearError`) и
/// пустые повторные стопы, чистится ТОЛЬКО успешным стартом (connected).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Основной native-канал: connected-ветка асинхронно дёргает uptime/CC-методы.
  // Default null достаточно (getTunnelUptimeMs → 0, cc* → no-op).
  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  // Control-каналы EventChannel'ов CommandClient: `_startCcStreams` вешает
  // подписки → EventChannel шлёт 'listen'; мокаем, чтобы не сыпать
  // MissingPluginException в консоль.
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late HomeController controller;

  TunnelStatusEvent event(TunnelStatus status, {String? reason}) {
    // §276 — raw обязан совпадать с тем, что реально шлёт native: enum
    // `VpnStatus` = 4 значения, строки 'Revoked' среди них нет. Revoke едет
    // как `Stopped` + флаг `revoked`.
    final raw = switch (status) {
      TunnelStatus.connected => 'Started',
      TunnelStatus.connecting => 'Starting',
      TunnelStatus.disconnected || TunnelStatus.revoked => 'Stopped',
      _ => status.name,
    };
    return TunnelStatusEvent(status: status, raw: raw, errorReason: reason);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('last_start_error_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    // Haptics дёргают SystemChannels.platform (unmocked) — глушим.
    HapticService.I.enabled = false;
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    controller = HomeController();
  });

  tearDown(() async {
    // dispose гасит heartbeat/autoPing/transient/groupsPull таймеры,
    // чтобы plain test() не ловил колбэки после завершения.
    controller.dispose();
    // Дать хвостам unawaited-futures connected-ветки дотечь под живыми моками.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('аварийный stop с errorReason → lastStartError + lastStartErrorAt', () {
    // Стартовое state = disconnected → сперва выходим из терминала (иначе
    // stale-terminal guard проглотит событие).
    controller.debugHandleStatusEvent(event(TunnelStatus.connecting));
    controller.debugHandleStatusEvent(event(TunnelStatus.disconnected,
        reason: 'Failed to start service: X'));

    expect(controller.state.lastStartError,
        'Stopped: Failed to start service: X');
    expect(controller.state.lastStartErrorAt, isNotNull);
    // lastError (UI-поле) выставлен той же причиной.
    expect(controller.state.lastError, 'Stopped: Failed to start service: X');
  });

  test('clearError() чистит lastError, но НЕ трогает lastStartError', () {
    controller.debugHandleStatusEvent(event(TunnelStatus.connecting));
    controller.debugHandleStatusEvent(
        event(TunnelStatus.disconnected, reason: 'boom'));
    final at = controller.state.lastStartErrorAt;

    controller.clearError();

    expect(controller.state.lastError, isEmpty);
    expect(controller.state.lastStartError, 'Stopped: boom');
    expect(controller.state.lastStartErrorAt, at);
  });

  test('повторный disconnected без errorReason сохраняет lastStartError', () {
    controller.debugHandleStatusEvent(event(TunnelStatus.connecting));
    controller.debugHandleStatusEvent(
        event(TunnelStatus.disconnected, reason: 'boom'));
    final at = controller.state.lastStartErrorAt;

    // Дребезг teardown: повторный Stopped в терминале (stale-terminal guard).
    controller.debugHandleStatusEvent(event(TunnelStatus.disconnected));
    expect(controller.state.lastStartError, 'Stopped: boom');
    expect(controller.state.lastStartErrorAt, at);

    // Полный цикл connecting → чистый Stopped (пустой reason в основной
    // ветке) — тоже НЕ затирает (симметрично lastError).
    controller.debugHandleStatusEvent(event(TunnelStatus.connecting));
    controller.debugHandleStatusEvent(event(TunnelStatus.disconnected));
    expect(controller.state.lastStartError, 'Stopped: boom');
    expect(controller.state.lastStartErrorAt, at);
  });

  test('успешный старт (connected) — единственная очистка', () {
    controller.debugHandleStatusEvent(event(TunnelStatus.connecting));
    controller.debugHandleStatusEvent(
        event(TunnelStatus.disconnected, reason: 'boom'));
    expect(controller.state.lastStartError, isNotEmpty);

    controller.debugHandleStatusEvent(event(TunnelStatus.connected));

    expect(controller.state.lastStartError, isEmpty);
    expect(controller.state.lastStartErrorAt, isNull);
  });

  test('revoked → lastStartError с текстом про другой VPN', () {
    controller.debugHandleStatusEvent(event(TunnelStatus.connecting));
    controller.debugHandleStatusEvent(event(TunnelStatus.revoked));

    expect(controller.state.lastStartError, contains('Another VPN app'));
    expect(controller.state.lastStartErrorAt, isNotNull);
    expect(controller.state.lastError, controller.state.lastStartError);
  });

  group('serializeHomeState (§250)', () {
    test('пустое состояние → last_start_error="" / last_start_error_at=null',
        () {
      final json = serializeHomeState(HomeState());
      expect(json.containsKey('last_start_error'), isTrue);
      expect(json.containsKey('last_start_error_at'), isTrue);
      expect(json['last_start_error'], '');
      expect(json['last_start_error_at'], isNull);
    });

    test('заполненное состояние → reason + ISO-8601 UTC timestamp', () {
      final json = serializeHomeState(HomeState(
        lastStartError: 'Stopped: Failed to start service: X',
        lastStartErrorAt: DateTime.utc(2026, 7, 6, 12, 30),
      ));
      expect(json['last_start_error'], 'Stopped: Failed to start service: X');
      expect(json['last_start_error_at'], '2026-07-06T12:30:00.000Z');
    });
  });
}
