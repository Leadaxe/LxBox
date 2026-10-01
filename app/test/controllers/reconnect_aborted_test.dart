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

/// 010-VPN_SERVICE · P4 — «Reconnect does not start on top of an unstopped
/// tunnel.» Если штатный stop внутри `reconnect()` не подтвердился (native
/// вернул false), start НЕ вызывается — контроллер выставляет
/// `stopTimedOutReconnectAborted` и выходит, не трогая `startVPN`.
///
/// Свидетель §591 P4 (не было юнит-покрытия). Мутация из промиса: стартовать
/// поверх неостановленного туннеля — тест ловит её через счётчик вызовов
/// `startVPN`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late HomeController controller;
  late int startVpnCalls;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('reconnect_aborted_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    HapticService.I.enabled = false;
    startVpnCalls = 0;
    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'stopVPN':
          return false; // штатный стоп не подтвердился
        case 'startVPN':
          startVpnCalls++;
          return true;
        default:
          return null;
      }
    });
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

  test(
      'stop не подтвердился → reconnect не зовёт startVPN и выставляет '
      'stopTimedOutReconnectAborted', () async {
    // Туннель должен выглядеть поднятым, иначе reconnect() сразу уйдёт в
    // ветку `start()` (wasUp=false) и не пройдёт через _stopInternal вовсе.
    controller.debugHandleStatusEvent(
      const TunnelStatusEvent(status: TunnelStatus.connected, raw: 'Started'),
    );
    expect(controller.state.tunnel, TunnelStatus.connected);

    await controller.reconnect();

    expect(controller.state.lastError,
        const ErrMsg(ErrKey.stopTimedOutReconnectAborted));
    expect(startVpnCalls, 0,
        reason: 'start не должен звать startVPN поверх неостановленного '
            'туннеля (мутация P4)');
    expect(controller.state.busy, isFalse);
  });
}
