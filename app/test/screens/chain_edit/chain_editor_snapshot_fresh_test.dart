// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/screens/chain_edit/chain_edit_flow.dart';
import 'package:lxbox/screens/chain_edit/chain_hop_targets.dart';
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

/// §731 (4PDA #2002) — редактор цепочки берёт цели из последнего собранного
/// конфига. Правки состава папки конфиг не пересобирают: без освежения снимка
/// новый узел числился «потерянным», а удалённый оставался в пикере до
/// перезахода на экран Servers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadEngineSections);

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const uriA = 'vless://u1@h1.example:443?type=ws&security=tls#Alpha';
  const uriB = 'vless://u2@h2.example:443?type=ws&security=tls#Beta';

  late Directory tempDir;
  late HomeController home;
  late SubscriptionController sub;
  late List<String> calls;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chain_snapshot_');
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
    await SettingsStorage.setAutoReloadOnChange(false);
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

  Future<Set<String>> offeredNodes() async {
    final cands = collectChainHopTargets(
      config: home.state.configModel,
      directions: await SettingsStorage.getDirections(),
      chains: const [],
      selfTag: 'route',
    );
    return {
      for (final c in cands)
        if (c.offered) c.tag,
    };
  }

  test('состав папки менялся после сборки → снимок целей пересобран',
      () async {
    await regenerateSourcesConfig(sub, home);
    expect(await offeredNodes(), contains('Alpha'));

    // Правки на экране папки: конфиг не пересобирается.
    await sub.addMembersToFolder(0, uriB);
    await sub.removeMemberAt(0, 0);
    expect(await offeredNodes(), contains('Alpha'),
        reason: 'предусловие: снимок устарел — удалённый узел ещё в целях');
    expect(await offeredNodes(), isNot(contains('Beta')));

    await refreshChainEditorSnapshot(sub, home);

    final fresh = await offeredNodes();
    expect(fresh, contains('Beta'), reason: 'новый узел — не «потерян»');
    expect(fresh, isNot(contains('Alpha')),
        reason: 'удалённый узел в пикер не предлагается');
  });

  test('источники не менялись → сборка не запускается', () async {
    await regenerateSourcesConfig(sub, home);
    final saves = calls.where((m) => m == 'saveConfig').length;

    await refreshChainEditorSnapshot(sub, home);

    expect(calls.where((m) => m == 'saveConfig').length, saves);
  });
}
