// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:fake_async/fake_async.dart';
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

/// 010-VPN_SERVICE · P14 — «A silent core is recognized.» Два подряд
/// heartbeat-тика (интервал 5с) без снапшота статус-стрима дольше 8с подряд
/// переводят туннель в `revoked` с `tunnelNotResponding` и дают штатную
/// попытку stop (`_tryCleanStop` → `vpn.stopVPN()`).
///
/// Свидетель §591 P14 (не было юнит-покрытия). Время фиктивное: watchdog
/// (`heartbeat.dart`) тикает `Timer.periodic`, а тишину считает по часам
/// `HomeController.heartbeatClockForTesting` — тест подставляет часы
/// fake-async, и прод-константы 5 с / 8 с проходят без живого ожидания.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = EventChannel('lxbox/cc/status');
  const ccGroupsMethod = MethodChannel('lxbox/cc/groups');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late HomeController controller;
  late int stopVpnCalls;

  /// Регистрируется внутри fakeAsync: мок доставляет событие через свой
  /// StreamController, и его подписка должна жить в fake-зоне, иначе
  /// снапшот придёт только после выхода из неё.
  void mockSilentStatusStream() {
    // §122 status-стрим: на 'listen' шлём РОВНО ОДИН снапшот (иначе
    // `_checkHeartbeat` видит `lastCcStatusAt == null` и трактует это как
    // «канал только поднимается», не считает тишину — см. heartbeat.dart),
    // дальше молчим — имитация «ядро молчит».
    messenger.setMockStreamHandler(
      ccStatus,
      MockStreamHandler.inline(
        onListen: (args, events) => events.success(const <String, Object?>{
          'uplink': 0,
          'downlink': 0,
          'uplinkTotal': 0,
          'downlinkTotal': 0,
          'memory': 0,
          'goroutines': 0,
          'connectionsIn': 0,
          'connectionsOut': 0,
        }),
        onCancel: (args) {},
      ),
    );
  }

  setUp(() async {
    tempDir =
        await Directory.systemTemp.createTemp('heartbeat_silent_core_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    HapticService.I.enabled = false;
    stopVpnCalls = 0;
    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'stopVPN':
          stopVpnCalls++;
          return true;
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(ccGroupsMethod, (call) async => null);
    controller = HomeController();
  });

  tearDown(() async {
    controller.dispose();
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(ccGroupsMethod, null);
    messenger.setMockStreamHandler(ccStatus, null);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test(
      'молчание status-стрима дольше 8с дважды подряд → revoked + '
      'tunnelNotResponding + попытка стопа', () {
    fakeAsync((async) {
      final t0 = DateTime.now();
      HomeController.heartbeatClockForTesting = () => t0.add(async.elapsed);
      addTearDown(() => HomeController.heartbeatClockForTesting = null);
      mockSilentStatusStream();

      controller.debugHandleStatusEvent(
        const TunnelStatusEvent(status: TunnelStatus.connected, raw: 'Started'),
      );
      async.flushMicrotasks();
      expect(controller.state.tunnel, TunnelStatus.connected);

      // Watchdog: интервал тика 5с, порог тишины 8с, 2 неудачных тика подряд
      // гасят туннель. Тик 5с — тишина 5с, ещё жив.
      async.elapse(const Duration(seconds: 6));
      expect(controller.state.tunnel, TunnelStatus.connected,
          reason: 'тишина 5с не превышает порога 8с');

      // Тики 10с и 15с — два неудачных подряд.
      async.elapse(const Duration(seconds: 10));
      expect(controller.state.tunnel, TunnelStatus.revoked,
          reason: 'ядро молчало > 8с дважды подряд — watchdog обязан признать '
              'его немым (P14)');
      expect(
          controller.state.lastError, const ErrMsg(ErrKey.tunnelNotResponding));

      // `_onTunnelDead` делает best-effort stop асинхронно (unawaited) — даём
      // микрозадачам/таймеру прогнаться.
      async.elapse(const Duration(milliseconds: 200));
      expect(stopVpnCalls, greaterThanOrEqualTo(1),
          reason: 'признание немого ядра должно попытаться штатно остановить '
              'туннель, а не просто сменить статус');
    });
  });
}
