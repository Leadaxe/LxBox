// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/screens/chain_edit/chain_edit_flow.dart';
import 'package:lxbox/services/haptic_service.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../../parser/engine_test_setup.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

/// §667 Д3 — `regenerateSourcesConfig` (§558: правка цепочки, добавление
/// источника на Servers) больше не делает reload безусловно: применение к
/// живому туннелю решает общий гейт §338 (`applyIfAutoReload`), то есть галка.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadEngineSections);

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const uriA = 'vless://u1@h1.example:443?type=ws&security=tls#Alpha';

  late Directory tempDir;
  late HomeController home;
  late SubscriptionController sub;
  late List<String> calls;

  int reloads() => calls.where((m) => m == 'reloadVPN').length;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('regen_gate_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    HapticService.I.enabled = false;
    calls = <String>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'reloadVPN':
        case 'saveConfig':
          return true;
        case 'getAutoRedirect':
          return false;
        case 'formatConfig':
          // Канон = то, что прислали: вердикт §324 сравнивает его со снимком.
          return (call.arguments as Map)['config'] as String;
      }
      return null;
    });
    for (final ch in [ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    home = HomeController();
    sub = SubscriptionController();
    await sub.init();
    await sub.addFolder('F');
    await sub.addMembersToFolder(0, uriA);
    // Туннель connected, ядро крутит заведомо другой конфиг → stale.
    home.debugSeedNodeState(group: 'vpn-1', activeNode: 'n1');
    home.debugSetRunningConfigRaw('{"running":"other"}');
  });

  tearDown(() async {
    home.cancelMassPing();
    home.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  test('галка выкл, туннель connected, конфиг изменился → reload НЕ вызван',
      () async {
    await SettingsStorage.setAutoReloadOnChange(false);

    final applied = await regenerateSourcesConfig(sub, home);

    expect(applied, isFalse, reason: 'снек не должен обещать «& applied»');
    expect(reloads(), 0);
    expect(home.state.configChangedNeedRestart, isTrue,
        reason: 'остаётся обычная плашка «restart VPN», как у прочих правок');
  });

  test('галка вкл → reload вызван', () async {
    await SettingsStorage.setAutoReloadOnChange(true);

    final applied = await regenerateSourcesConfig(sub, home);

    expect(applied, isTrue);
    expect(reloads(), 1);
    expect(home.state.configChangedNeedRestart, isFalse);
  });
}
