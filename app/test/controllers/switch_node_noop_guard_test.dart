// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/services/automation/event_emitter.dart';
import 'package:lxbox/services/automation/handlers.dart' as automation;
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
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

/// §290 — no-op guard: SWITCH_NODE на уже активную ноду не делает re-select и
/// не рвёт соединения, но шлёт подтверждающее `NODE_ALREADY_ACTIVE`. На другую
/// ноду — прежний путь (`ccSelectOutbound` вызывается).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late HomeController controller;
  late List<String> methodCalls;
  late List<(String, Map<String, Object?>)> emitted;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('switch_guard_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    HapticService.I.enabled = false;
    methodCalls = [];
    messenger.setMockMethodCallHandler(methods, (call) async {
      methodCalls.add(call.method);
      // selectOutbound должен «удаться», чтобы switchNode не свалился в error.
      if (call.method == 'ccSelectOutbound') return true;
      if (call.method == 'ccGetGroups') return <dynamic>[];
      return null;
    });
    for (final ch in [ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    controller = HomeController();
    emitted = [];
    // §290 событие идёт под категорией State — включаем и перехватываем.
    AutomationEventEmitter.I.debugConfigureForTest(
      state: true,
      onSend: (a, e) => emitted.add((a, e)),
    );
    // §290 — привязать контроллер к registry, чтобы automation-хендлеры
    // (actionSwitchNode/actionSetGroup) видели его через requireHome().
    DebugRegistry.I.home = controller;
  });

  tearDown(() async {
    DebugRegistry.I.home = null;
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    AutomationEventEmitter.I.debugConfigureForTest(); // сброс
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  DebugContext ctx() =>
      DebugContext(registry: DebugRegistry.I, appStartedAt: DateTime(2026));

  test('switchNode на уже активную ноду — no-op + NODE_ALREADY_ACTIVE', () async {
    controller.debugSeedNodeState(group: 'vpn-1', activeNode: '🇫🇮node');

    await controller.switchNode('🇫🇮node');

    expect(methodCalls, isNot(contains('ccSelectOutbound')),
        reason: 're-select не должен вызываться на активную ноду');
    expect(methodCalls, isNot(contains('ccCloseConnection')),
        reason: 'соединения не должны рваться на no-op');
    expect(emitted.map((e) => e.$1), ['NODE_ALREADY_ACTIVE']);
    expect(emitted.single.$2['tag'], '🇫🇮node');
    expect(emitted.single.$2['group'], 'vpn-1');
  });

  test('switchNode на другую ноду — прежний путь (ccSelectOutbound)', () async {
    controller.debugSeedNodeState(group: 'vpn-1', activeNode: '🇫🇮node');

    await controller.switchNode('🇩🇪other');

    expect(methodCalls, contains('ccSelectOutbound'));
    expect(emitted.map((e) => e.$1), isNot(contains('NODE_ALREADY_ACTIVE')));
  });

  // ─── §290 automation preconditions (F1/F3) ─────────────────────────────────

  test('actionSwitchNode: группа выбрана, туннель опущен → Conflict (не немой)',
      () async {
    // group != null, но tunnelUp == false — раньше switchNode молча return'ил.
    controller.debugSeedNodeState(
        group: 'vpn-1', activeNode: '🇫🇮node', tunnelUp: false);

    await expectLater(
      automation.actionSwitchNode('🇩🇪other', ctx()),
      throwsA(isA<Conflict>()),
    );
    expect(methodCalls, isNot(contains('ccSelectOutbound')));
  });

  test('actionSetGroup: несуществующая группа → NotFound (без ложного события)',
      () async {
    controller.debugSeedNodeState(
        group: 'vpn-1', activeNode: '🇫🇮node', groups: ['vpn-1', 'work']);

    await expectLater(
      automation.actionSetGroup('ghost', ctx()),
      throwsA(isA<NotFound>()),
    );
    expect(emitted.map((e) => e.$1), isNot(contains('ACTIVE_GROUP_CHANGED')));
  });

  test('actionSetGroup: существующая группа → без броска', () async {
    controller.debugSeedNodeState(
        group: 'vpn-1', activeNode: '🇫🇮node', groups: ['vpn-1', 'work']);

    // не должно бросить (группа есть в списке)
    await automation.actionSetGroup('work', ctx());
  });
}
