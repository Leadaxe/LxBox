// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/services/haptic_service.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/vpn/cc_channel.dart';
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

/// Задача 724 (issue #212) — главный экран открывается на последнем выбранном
/// Направлении: текущее → сохранённое → первое; `route.final` не участвует.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pickDirection', () {
    const groups = ['warp', 'vpn-1', 'vpn-2'];

    test('текущее в списке остаётся, даже если сохранено другое', () {
      expect(
        HomeController.pickDirection(
            current: 'vpn-2', saved: 'vpn-1', groups: groups),
        'vpn-2',
      );
    });

    test('текущего нет — берётся сохранённое', () {
      expect(
        HomeController.pickDirection(
            current: null, saved: 'vpn-1', groups: groups),
        'vpn-1',
      );
      expect(
        HomeController.pickDirection(
            current: 'gone', saved: 'vpn-2', groups: groups),
        'vpn-2',
      );
    });

    test('ни текущего, ни сохранённого — первое в списке', () {
      expect(
        HomeController.pickDirection(
            current: null, saved: null, groups: groups),
        'warp',
      );
      expect(
        HomeController.pickDirection(
            current: null, saved: 'gone', groups: groups),
        'warp',
      );
    });

    test('пустой список — null', () {
      expect(
        HomeController.pickDirection(
            current: 'vpn-1', saved: 'vpn-1', groups: const []),
        isNull,
      );
    });
  });

  group('сохранение между запусками', () {
    const methods = MethodChannel('com.leadaxe.lxbox/methods');
    const ccStatus = MethodChannel('lxbox/cc/status');
    const ccGroups = MethodChannel('lxbox/cc/groups');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    late Directory tempDir;

    CcGroup selector(String tag) => CcGroup(
          tag: tag,
          type: 'selector',
          selectable: true,
          selected: '',
          isExpand: false,
          items: const [],
        );
    final snapshot = [selector('warp'), selector('vpn-1'), selector('vpn-2')];

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('home_direction_test_');
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
      SettingsStorage.resetCacheForTesting();
      HapticService.I.enabled = false;
      for (final ch in [methods, ccStatus, ccGroups]) {
        messenger.setMockMethodCallHandler(ch, (call) async => null);
      }
    });

    tearDown(() async {
      for (final ch in [methods, ccStatus, ccGroups]) {
        messenger.setMockMethodCallHandler(ch, null);
      }
      SettingsStorage.resetCacheForTesting();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('без сохранённого открывается первое и само себя не запоминает',
        () async {
      final c = HomeController();
      addTearDown(c.dispose);
      await c.loadSavedDirection();
      c.debugApplyGroups(snapshot);

      expect(c.state.selectedGroup, 'warp');
      expect(await SettingsStorage.getHomeDirection(), '');
    });

    test('явный выбор пишется и поднимается новым контроллером', () async {
      final first = HomeController();
      first.debugApplyGroups(snapshot);
      first.setSelectedGroup('vpn-2');
      // Запись не ждётся вызывающим — даём ей завершиться.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await SettingsStorage.getHomeDirection(), 'vpn-2');
      first.dispose();

      final second = HomeController();
      addTearDown(second.dispose);
      await second.loadSavedDirection();
      second.debugApplyGroups(snapshot);
      expect(second.state.selectedGroup, 'vpn-2');
    });

    test('пустой снимок на старте туннеля не теряет выбор', () async {
      final c = HomeController();
      addTearDown(c.dispose);
      c.debugApplyGroups(snapshot);
      c.setSelectedGroup('vpn-1');

      c.debugApplyGroups(const []);
      expect(c.state.selectedGroup, isNull);
      c.debugApplyGroups(snapshot);
      expect(c.state.selectedGroup, 'vpn-1');
    });
  });
}
