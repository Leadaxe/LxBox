// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/services/haptic_service.dart';
import 'package:lxbox/services/settings_storage.dart';
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

/// §667 Р4 (Д5) — `saveParsedConfig` при живом туннеле со снимком running
/// берёт флаг «устарел» из вердикта §324, а не из текстового диффа с
/// ПРЕДЫДУЩЕЙ записью: вторая запись того же конфига раньше давала
/// `changed=false` и гасила флаг, хотя ядро так и крутит старый конфиг.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const saved = '{"outbounds":[{"type":"direct","tag":"direct"}]}';

  late Directory tempDir;
  late HomeController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('save_staleness_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    HapticService.I.enabled = false;
    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
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
    controller = HomeController();
    controller.debugSeedNodeState(group: 'vpn-1', activeNode: 'n1');
  });

  tearDown(() async {
    controller.cancelMassPing();
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('две записи одного конфига при running ≠ saved → флаг после обеих',
      () async {
    controller.debugSetRunningConfigRaw('{"outbounds":[]}');

    expect(await controller.saveParsedConfig(saved), isTrue);
    expect(controller.state.configChangedNeedRestart, isTrue);

    // Reload по первой записи сорвался (cooldown) — пишем тот же конфиг ещё
    // раз (Servers → Update all, повторная пересборка экрана).
    expect(await controller.saveParsedConfig(saved), isTrue);
    expect(controller.state.configChangedNeedRestart, isTrue,
        reason: 'Д5 — идентичная повторная запись не должна гасить «устарел»');
  });

  test('running == saved → fresh гасит флаг даже при прежнем true (§323)',
      () async {
    controller.debugSetRunningConfigRaw(saved);
    controller.markConfigChangedNeedRestart();
    expect(controller.state.configChangedNeedRestart, isTrue);

    expect(await controller.saveParsedConfig(saved), isTrue);
    expect(controller.state.configChangedNeedRestart, isFalse,
        reason: 'ядро уже на этом конфиге — применять нечего');
  });

  test('без снимка running — текстовый дифф со sticky-правилом как раньше',
      () async {
    // Снапшота нет (старое ядро / окно до захвата): вердикт unknown.
    expect(await controller.saveParsedConfig(saved), isTrue);
    expect(controller.state.configChangedNeedRestart, isTrue,
        reason: 'первая запись при живом туннеле — изменилось');
    expect(await controller.saveParsedConfig(saved), isTrue);
    expect(controller.state.configChangedNeedRestart, isFalse,
        reason: '§323 — идентичная запись без снимка гасит флаг');
  });
}
