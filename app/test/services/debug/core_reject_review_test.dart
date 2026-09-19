// ignore_for_file: depend_on_referenced_packages

// Фича 478 — находки ревью guard_builder_api (Debug API).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/core_reject/core_reject_state.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/core_reject.dart';
import 'package:lxbox/services/debug/handlers/nodes.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/tag_resolver.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../../parser/engine_test_setup.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tempRoot);
  final String tempRoot;
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;
  late SubscriptionController controller;

  DebugContext ctx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 9, 19),
      );

  DebugRequest req(
    String method,
    String path, {
    Map<String, String> query = const {},
    List<int> body = const [],
  }) =>
      DebugRequest.forTest(
        method: method,
        path: path,
        query: query,
        body: body,
      );

  Map<String, dynamic> asMap(DebugResponse r) =>
      (r as JsonResponse).body as Map<String, dynamic>;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    CoreRejectState.I.resetForTest();
    tempDir = await Directory.systemTemp.createTemp('core_reject_review_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    controller = SubscriptionController();
    await controller.init();
    DebugRegistry.I.sub = controller;
  });

  tearDown(() async {
    DebugRegistry.I.sub = null;
    CoreRejectState.I.resetForTest();
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  group('POST /core_reject/prompt', () {
    test('answer=keep до pending ставит в очередь', () async {
      final body = asMap(await coreRejectHandler(
        req('POST', '/core_reject/prompt', query: {'answer': 'keep'}),
        ctx(),
      ));
      expect(body['queued'], isTrue);
      expect(body['answer'], 'keep');
    });
  });

  group('POST /core_reject/enable', () {
    test('принимает emitted-тег с префиксом подписки', () async {
      await controller.addFromInput(
        'vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls#Frankfurt',
      );
      final sub = SubscriptionServers(
        id: controller.entries.single.id,
        name: 'Sub',
        enabled: true,
        tagPrefix: '🇩🇪',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        nodes: [
          parseUri(
                  'vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls#Frankfurt')!,
        ],
      );
      await controller.replaceList(0, sub);
      await controller.generateConfig();
      final node = sub.nodes.single;
      final emitted = TagResolver.displayTag('🇩🇪', node.tag);
      expect(
        await controller.disableNodeByCoreTag(emitted, 'bad key'),
        isTrue,
      );

      final body = asMap(await coreRejectHandler(
        req('POST', '/core_reject/enable', query: {'tag': emitted}),
        ctx(),
      ));
      expect(body['enabled'], isTrue);
      expect(body['tag'], emitted);
      final stored = controller.entries.single.list as SubscriptionServers;
      expect(stored.disabledHashes.containsKey(node.tag), isFalse);
      expect(stored.nodeWarnings.containsKey(node.tag), isFalse);
    });
  });

  group('GET /nodes/link', () {
    test('без reveal → error reveal required', () async {
      await controller.addFromInput(
          'vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls#Alpha');
      final tag = controller.entries.single.list.nodes.single.tag;
      final body = asMap(
          await nodesHandler(req('GET', '/nodes/link', query: {'tag': tag}), ctx()));
      expect(body['error'], 'reveal required');
      expect(body.containsKey('uri'), isFalse);
    });
  });
}
