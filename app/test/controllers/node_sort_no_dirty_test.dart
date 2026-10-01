// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/models/home_state.dart';
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

/// P9 (007-NODE_LIST / FEATURE.md) — «non-config savers (sort/ping) do NOT
/// raise the flag»: смена режима сортировки (`setSortMode`/`cycleSortMode`)
/// и фиксация ручного порядка (`commitManualReorder`) — чисто UI-состояние
/// (persisted в `lxbox_settings.json`, не в конфиг ядра) и НЕ должны
/// выставлять `configChangedNeedRestart`. Свидетель отсутствовал
/// (`no witness`, task 591 §007, строка 293).
///
/// Мутация, под которую тест обязан падать: если сортировка/ручной порядок
/// начнут звать `markConfigChangedNeedRestart()` (или иначе выставлять
/// `configChangedNeedRestart: true`) — тест поймает `isTrue` там, где
/// ожидается `isFalse`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late HomeController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('node_sort_no_dirty_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    HapticService.I.enabled = false;
    messenger.setMockMethodCallHandler(methods, (call) async => null);
    for (final ch in [ccStatus, ccGroups]) {
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

  test('setSortMode с туннелем up НЕ поднимает configChangedNeedRestart',
      () async {
    controller.debugSeedNodeState(group: 'vpn-1', activeNode: '🇫🇮node');
    expect(controller.state.configChangedNeedRestart, isFalse);

    controller.setSortMode(NodeSortMode.nameAsc);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(controller.state.sortMode, NodeSortMode.nameAsc);
    expect(controller.state.configChangedNeedRestart, isFalse,
        reason: 'смена режима сортировки — не config-significant (§100)');
  });

  test('cycleSortMode с туннелем up НЕ поднимает configChangedNeedRestart',
      () async {
    controller.debugSeedNodeState(group: 'vpn-1', activeNode: '🇫🇮node');

    controller.cycleSortMode();
    controller.cycleSortMode();
    controller.cycleSortMode();
    // _persistSort — unawaited fire-and-forget save; дать ему завершиться
    // до tearDown (иначе гонка с удалением tempDir следующим тестом).
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(controller.state.configChangedNeedRestart, isFalse);
  });

  test(
      'commitManualReorder с туннелем up НЕ поднимает configChangedNeedRestart '
      'и персистит mode+order (переживает рестарт приложения)', () async {
    controller.debugSeedNodeState(
        group: 'vpn-1',
        activeNode: '🇫🇮node',
        groups: const ['vpn-1', 'a', 'b', 'c']);

    controller.commitManualReorder(const ['c', 'a', 'b']);

    expect(controller.state.sortMode, NodeSortMode.manual);
    expect(controller.state.manualOrder, ['c', 'a', 'b']);
    expect(controller.state.configChangedNeedRestart, isFalse,
        reason: 'ручной порядок — UI-состояние, не идёт в конфиг ядра');

    // Персист в lxbox_settings.json — восстановление после рестарта.
    final persisted = await SettingsStorage.getNodeSort();
    expect(persisted.mode, 'manual');
    expect(persisted.order, ['c', 'a', 'b']);
  });
}
