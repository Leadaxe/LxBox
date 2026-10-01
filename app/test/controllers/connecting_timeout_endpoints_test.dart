// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/models/home_state.dart';
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

/// §519 — порог safety-таймаута фазы `connecting` и причина принудительного
/// стопа по нему.
///
/// Предыстория. §140 поставил фиксированные 15с, считая, что `connecting`
/// дольше порога — это «медленный, но живой старт по сотовой». Демо 24.09.2026
/// показало третий случай: старт живой, но **арифметически** длиннее порога.
/// Пост-старт ядра поднимает wireguard/AWG-endpoint'ы СТРОГО ПОСЛЕДОВАТЕЛЬНО
/// (`adapter/endpoint/manager.go` — цикл по `m.endpoints`), 6.8–9.3с на
/// endpoint; на конфиге из 8 AWG вышло `post-start manager completed (21.48s)`,
/// и force-stop убивал уже состоявшееся рукопожатие. Наружу это выглядело
/// «молча не соединяется»: `last_error`/`last_start_error` пустые.
///
/// Здесь проверяется контракт:
///   1. порог линейно растёт с числом endpoint'ов в конфиге;
///   2. база 15с сохранена для «ядро молчит» (конфиг без endpoint'ов);
///   3. порог ограничен потолком (конфиг на сотню endpoint'ов не отключает
///      страховку навсегда);
///   4. Debug-override (§140) имеет приоритет и масштабирование отменяет —
///      иначе on-device тест force-stop'а с `connecting=500` не сработал бы;
///   5. срабатывание таймаута оставляет ПРИЧИНУ (`stopReason` +
///      `lastStartError`), а не только UI-строку.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late HomeController controller;

  /// Конфиг с [endpoints] wireguard-endpoint'ами и [outbounds] vless-узлами.
  /// Считать должны ТОЛЬКО endpoint'ы: vless живёт в `outbounds` и пост-старт
  /// ядра на нём не блокируется.
  String configWith({required int endpoints, int outbounds = 0}) {
    final eps = [
      for (var i = 0; i < endpoints; i++)
        '{"type":"wireguard","tag":"wg-$i",'
            '"peers":[{"address":"example-$i.org","port":9494}]}'
    ].join(',');
    final obs = [
      for (var i = 0; i < outbounds; i++)
        '{"type":"vless","tag":"vless-$i","server":"h$i.example.org","server_port":443}'
    ].join(',');
    return '{"endpoints":[$eps],"outbounds":[$obs]}';
  }

  TunnelStatusEvent connecting() => const TunnelStatusEvent(
      status: TunnelStatus.connecting, raw: 'Starting');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('connecting_timeout_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    HapticService.I.enabled = false;
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    controller = HomeController();
  });

  tearDown(() async {
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('конфиг без endpoint\'ов — база §140 сохранена (15с)', () {
    controller.debugSetConfigRaw(configWith(endpoints: 0, outbounds: 4));

    final t = controller.debugEffectiveConnectingTimeout;
    expect(t.endpoints, 0, reason: 'vless-узлы в outbounds не endpoint\'ы');
    expect(t.connectingMs, const Duration(seconds: 15).inMilliseconds,
        reason: 'случай «ядро молчит» не должен получить надбавку');
  });

  test('порог растёт линейно с числом endpoint\'ов', () {
    controller.debugSetConfigRaw(configWith(endpoints: 1, outbounds: 1));
    final one = controller.debugEffectiveConnectingTimeout;
    controller.debugSetConfigRaw(configWith(endpoints: 8, outbounds: 4));
    final eight = controller.debugEffectiveConnectingTimeout;

    expect(one.endpoints, 1);
    expect(eight.endpoints, 8);
    // Шаг постоянный — надбавка ровно за endpoint, а не «на глазок».
    final step = (eight.connectingMs - one.connectingMs) / 7;
    expect(step, (one.connectingMs - 15000).toDouble());

    // Главный регресс демо: конфиг из ОДНОГО AWG + одного vless не проходил
    // фиксированные 15с (endpoint стартует 6.8–9.3с).
    expect(one.connectingMs, greaterThan(15000));
    // И конфиг из 8 AWG обязан перекрыть замеренные 21.48с пост-старта.
    expect(eight.connectingMs,
        greaterThan(const Duration(milliseconds: 21480).inMilliseconds));
  });

  test('порог ограничен потолком — страховка не выключается навсегда', () {
    controller.debugSetConfigRaw(configWith(endpoints: 200));

    final t = controller.debugEffectiveConnectingTimeout;
    expect(t.endpoints, 200);
    expect(t.connectingMs, const Duration(minutes: 4).inMilliseconds);
  });

  test('Debug-override (§140) имеет приоритет и отменяет масштабирование', () {
    controller.debugSetConfigRaw(configWith(endpoints: 8));
    // §140 — ровно этот сценарий: `connecting=500` для on-device проверки
    // force-stop'а. Масштабирование не должно его раздуть.
    controller.debugSetTransientTimeouts(connectingMs: 500);

    expect(controller.debugEffectiveConnectingTimeout.connectingMs, 500);
  });

  test('таймаут connecting оставляет причину, а не молчит', () async {
    controller.debugSetConfigRaw(configWith(endpoints: 1));
    // Override даёт короткий порог, чтобы не ждать реальный бюджет. Причина
    // при этом обязана нести ИМЕННО его значение — текст не должен врать.
    controller.debugSetTransientTimeouts(connectingMs: 2000);
    controller.debugHandleStatusEvent(connecting());

    // Таймер ставится Timer'ом реального времени — пережидаем порог.
    await Future<void>.delayed(const Duration(milliseconds: 2400));

    expect(controller.state.tunnel, TunnelStatus.disconnected);
    expect(controller.state.stopReason,
        const StopStartTimeout(seconds: 2, endpoints: 1),
        reason: 'до §519 stopReason оставался null — «молча не соединяется»');
    // Машинный дубль для Debug API / дампа: непустой и по-английски.
    expect(controller.state.lastStartError, isNotEmpty);
    expect(controller.state.lastStartError, contains('Start timed out'));
    expect(controller.state.lastStartError, contains('1 endpoints'));
    expect(controller.state.lastStartErrorAt, isNotNull);
    // UI-строка — та же причина, а не generic «Connection timed out».
    expect(controller.state.lastError,
        const StopReasonMsg(StopStartTimeout(seconds: 2, endpoints: 1)));
  });
}
