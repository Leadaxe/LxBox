// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/models/ui_msg.dart';
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

/// §415 — контракт «Stop timed out» ровно один: ошибку показываем ТОЛЬКО когда
/// native вернул `false` (штатная остановка не уложилась в нативный бюджет).
/// Медленная, но успешная остановка (тяжёлый туннель, teardown ~5.2с на замере)
/// ошибки давать не должна — раньше давала, потому что нативный бюджет 5с
/// истекал раньше конца teardown'а.
///
/// Нативный бюджет (`BoxVpnService.STOP_AWAIT_TIMEOUT_MS`) тестами отсюда не
/// покрывается — это Kotlin/coroutines, за границей MethodChannel. Здесь
/// проверяется Dart-контракт над его ответом.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late HomeController controller;

  /// Ставит мок native-канала, где `stopVPN` отвечает [stopResult] через
  /// [delay] (эмуляция медленного teardown'а).
  void mockStop({required bool stopResult, Duration delay = Duration.zero}) {
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'stopVPN') {
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        return stopResult;
      }
      return null;
    });
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('stop_timeout_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    HapticService.I.enabled = false;
    for (final ch in [ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    controller = HomeController();
  });

  tearDown(() async {
    controller.dispose();
    messenger.setMockMethodCallHandler(methods, null);
    for (final ch in [ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('успешный стоп не выставляет stopTimedOut', () async {
    mockStop(stopResult: true);

    await controller.stop();

    expect(controller.state.lastError, isNull);
    expect(controller.state.busy, isFalse);
  });

  test('медленный, но успешный стоп (teardown с задержкой) — тоже без ошибки',
      () async {
    // Ключевой кейс §415: native отвечает не мгновенно, но УСПЕХОМ. Пока он
    // укладывается в Dart-бюджет `_Timeouts.stopVpn`, ошибки быть не должно.
    mockStop(stopResult: true, delay: const Duration(milliseconds: 300));

    await controller.stop();

    expect(controller.state.lastError, isNull);
  });

  test('провал штатного стопа (native вернул false) даёт stopTimedOut',
      () async {
    mockStop(stopResult: false);

    await controller.stop();

    expect(controller.state.lastError, const ErrMsg(ErrKey.stopTimedOut));
    expect(controller.state.busy, isFalse);
  });

  test(
      'эскалация stopping-таймаута больше Dart-бюджета stopVPN — '
      'force-stop не гонится со штатной остановкой', () async {
    // Лестница бюджетов §415: native 9с < Dart stopVPN 10с < эскалация 12с.
    // Проверяем нижнюю границу эскалации: она обязана быть строго больше
    // Dart-бюджета, иначе force-stop прилетит поверх ещё живой штатной
    // остановки (ровно тот баг, из-за которого юзер видел ложную ошибку).
    const dartStopBudget = Duration(seconds: 10);
    final stoppingMs = controller.debugTransientTimeouts.stoppingMs;

    expect(stoppingMs, greaterThan(dartStopBudget.inMilliseconds));
  });
}
