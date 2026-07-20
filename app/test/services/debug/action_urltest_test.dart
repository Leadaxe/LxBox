// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/action.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
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

/// §290 — `/action/urltest` scope-роутер + делегация group-scope в shared
/// `actionUrltestGroup` (общая база с Automation API, без дубля precondition'ов).
/// Debug `/action/*` раньше не был покрыт тестами — заодно закрываем дыру.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late HomeController controller;

  DebugContext ctx() =>
      DebugContext(registry: DebugRegistry.I, appStartedAt: DateTime.utc(2026));

  Map<String, Object?> body(DebugResponse r) =>
      (r as JsonResponse).body as Map<String, Object?>;

  DebugRequest post(String qs) => DebugRequest(
        method: 'POST',
        uri: Uri.parse('http://127.0.0.1:9269/action/urltest$qs'),
        headers: const {},
        body: Uint8List(0),
        receivedAt: DateTime.utc(2026),
      );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('action_urltest_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    HapticService.I.enabled = false;
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    controller = HomeController();
    DebugRegistry.I.home = controller;
  });

  tearDown(() async {
    DebugRegistry.I.home = null;
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('non-POST → BadRequest', () {
    final req = DebugRequest(
      method: 'GET',
      uri: Uri.parse('http://127.0.0.1:9269/action/urltest?all=1'),
      headers: const {},
      body: Uint8List(0),
      receivedAt: DateTime.utc(2026),
    );
    expect(() => actionHandler(req, ctx()), throwsA(isA<BadRequest>()));
  });

  test('ни один scope → BadRequest', () {
    expect(() => actionHandler(post(''), ctx()), throwsA(isA<BadRequest>()));
  });

  test('несколько scope сразу → BadRequest', () {
    expect(() => actionHandler(post('?tag=a&all=1'), ctx()),
        throwsA(isA<BadRequest>()));
  });

  test('tag scope: пустой tag → BadRequest', () {
    expect(() => actionHandler(post('?tag='), ctx()),
        throwsA(isA<BadRequest>()));
  });

  test('cancel scope → ok', () async {
    final r = await actionHandler(post('?cancel=1'), ctx());
    expect(r, isA<JsonResponse>());
    expect(body(r)['scope'], 'cancel');
  });

  // ─── delegated group scope (общая база с Automation) ───

  test('group scope, tunnel down → Conflict (делегация в shared handler)',
      () async {
    // tunnelUp == false — тот же Conflict, что actionUrltestGroup.
    controller.debugSeedNodeState(
        group: 'vpn-1', activeNode: 'n', tunnelUp: false);
    await expectLater(
      actionHandler(post('?group=vpn-1'), ctx()),
      throwsA(isA<Conflict>()),
    );
  });

  test('group scope: пустой group → BadRequest', () {
    expect(() => actionHandler(post('?group='), ctx()),
        throwsA(isA<BadRequest>()));
  });

  test('group scope, tunnel up → ok(scope:group)', () async {
    controller.debugSeedNodeState(group: 'vpn-1', activeNode: 'n');
    final r = await actionHandler(post('?group=vpn-1'), ctx());
    expect(body(r)['scope'], 'group');
    expect(body(r)['group'], 'vpn-1');
  });

  test('all scope → ok(scope:mass)', () async {
    controller.debugSeedNodeState(group: 'vpn-1', activeNode: 'n');
    final r = await actionHandler(post('?all=1'), ctx());
    expect(body(r)['scope'], 'mass');
  });
}
