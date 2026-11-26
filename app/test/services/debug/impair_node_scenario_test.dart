// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/home/node_list_presenter.dart' show protoLabel;
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/directions.dart';
import 'package:lxbox/services/debug/handlers/folders.dart';
import 'package:lxbox/services/debug/handlers/nodes.dart';
import 'package:lxbox/services/debug/handlers/subs.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
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

/// §762 — узел `impair` скриптом через Debug API: создание `POST /subs`
/// (тег как передан, без эмодзи), правка и удаление `/subs/{id}`, detour
/// узла по тегу `PATCH /nodes/{tag}`; подпись протокола в строке узла.
void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;
  late SubscriptionController controller;

  const impairJson = '{"type": "impair", "tag": "imp-test", '
      '"link_params": {"delay": "30ms"}}';
  const uriA = 'vless://u1@h1.example:443?type=ws&security=tls#Alpha';

  DebugContext ctx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 11, 26),
      );

  DebugRequest req(String method, String path,
          {Map<String, dynamic>? body}) =>
      DebugRequest.forTest(
        method: method,
        path: path,
        body: body == null ? const [] : utf8.encode(jsonEncode(body)),
      );

  Map<String, dynamic> asMap(DebugResponse r) =>
      (r as JsonResponse).body as Map<String, dynamic>;

  Future<Map<String, dynamic>> create(String input) async {
    final r = await subsHandler(req('POST', '/subs', body: {'input': input}),
        ctx());
    expect((r as JsonResponse).status, 201);
    return asMap(r);
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('impair_node_');
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
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  test('POST /subs: impair — тег как передан, в ответе tags', () async {
    final b = await create(impairJson);
    expect(b['kind'], 'UserServer');
    expect(b['tags'], ['imp-test']);
    final e = controller.entries.single;
    expect(e.list.nodes.single.tag, 'imp-test');
    expect(e.list.nodes.single.protocol, 'impair');
    expect((e.list as UserServer).rawBody, contains('"imp-test"'));
  });

  test('обычный узел по-прежнему получает эмодзи, tags с ним', () async {
    final b = await create(uriA);
    final tag = (b['tags'] as List).single as String;
    expect(tag, endsWith('Alpha'));
    expect(tag, isNot('Alpha'));
    expect(controller.entries.single.list.nodes.single.tag, tag);
  });

  test('PATCH /subs/{id} и DELETE /subs/{id} для impair', () async {
    final id = (await create(impairJson))['id'] as String;
    final p = asMap(await subsHandler(
        req('PATCH', '/subs/$id',
            body: {'name': 'Impair', 'override_detour': 'Alpha'}),
        ctx()));
    expect(p['title'], 'Impair');
    expect(p['override_detour'], {'tag': 'Alpha'});
    final d = asMap(await subsHandler(req('DELETE', '/subs/$id'), ctx()));
    expect(d['action'], 'subs-delete');
    expect(controller.entries, isEmpty);
  });

  test('PATCH /nodes/{tag}: detour одиночного сервера на impair и снятие',
      () async {
    final tag = ((await create(uriA))['tags'] as List).single as String;
    await create(impairJson);
    final path = '/nodes/${Uri.encodeComponent(tag)}';
    final r = asMap(await nodesHandler(
        req('PATCH', path, body: {'detour': 'imp-test'}), ctx()));
    expect(r['kind'], 'UserServer');
    expect(r['detour'], {'tag': 'imp-test'});
    expect(controller.entries.first.overrideDetour.tag, 'imp-test');

    final off = asMap(
        await nodesHandler(req('PATCH', path, body: {'detour': null}), ctx()));
    expect(off['detour'], isNull);
    expect(controller.entries.first.overrideDetour.tag, isEmpty);
  });

  test('PATCH /nodes/{tag}: член папки — detour члена', () async {
    final fr = await foldersHandler(
        req('POST', '/folders', body: {'name': 'F'}), ctx());
    final fid = asMap(fr)['id'] as String;
    await foldersHandler(
        req('POST', '/folders/$fid/members', body: {'input': uriA}), ctx());
    await create(impairJson);
    final folder = controller.entries
        .firstWhere((e) => e.list is FolderServers)
        .list as FolderServers;
    final memberTag = folder.members.single.node!.tag;
    final r = asMap(await nodesHandler(
        req('PATCH', '/nodes/${Uri.encodeComponent(memberTag)}',
            body: {'detour': 'imp-test'}),
        ctx()));
    expect(r['kind'], 'FolderServers');
    final now = controller.entries
        .firstWhere((e) => e.list is FolderServers)
        .list as FolderServers;
    expect(now.members.single.detour.tag, 'imp-test');
  });

  test('PATCH /nodes/{tag}: нет тела, нет узла, чужой метод', () async {
    await create(impairJson);
    await expectLater(
        nodesHandler(req('PATCH', '/nodes/imp-test', body: {}), ctx()),
        throwsA(isA<BadRequest>()));
    await expectLater(
        nodesHandler(
            req('PATCH', '/nodes/nope', body: {'detour': null}), ctx()),
        throwsA(isA<NotFound>()));
    await expectLater(nodesHandler(req('GET', '/nodes/imp-test'), ctx()),
        throwsA(isA<NotFound>()));
  });

  Map<String, dynamic> outboundByTag(Map<String, dynamic> cfg, String tag) {
    for (final k in ['outbounds', 'endpoints']) {
      for (final o in (cfg[k] as List? ?? const [])) {
        if (o is Map && o['tag'] == tag) return o.cast<String, dynamic>();
      }
    }
    fail('no outbound "$tag" in config');
  }

  test('сборка: impair как есть, detour в обе стороны, фильтр Направления',
      () async {
    final alpha = ((await create(uriA))['tags'] as List).single as String;
    // Ключ `detour` в теле impair разбор не принимает (ссылка на узел вне
    // документа) — detour ставится записи: шаг 1 сценария.
    final b = await create(jsonEncode({
      'type': 'impair',
      'tag': 'imp-test',
      'seed': 1,
      'link_params': {'delay': '30ms'},
    }));
    expect(b['tags'], ['imp-test']);
    await nodesHandler(
        req('PATCH', '/nodes/imp-test', body: {'detour': alpha}), ctx());
    await directionsHandler(
        req('POST', '/directions', body: {
          // vpn-1: на него смотрит route.final шаблона (в пустом хранилище
          // теста Направлений нет).
          'tag': 'vpn-1',
          'label': 'Impair lab',
          'node_filter': '^imp-',
          'auto': {'mode': 'round_robin', 'balancer': {'pool': 3}},
        }),
        ctx());
    var cfg = jsonDecode((await controller.generateConfig())!)
        as Map<String, dynamic>;
    final imp = outboundByTag(cfg, 'imp-test');
    expect(imp['type'], 'impair');
    expect(imp['link_params'], {'delay': '30ms'});
    expect(imp['seed'], 1);
    expect(imp['detour'], alpha);
    expect(controller.lastEmittedTagMap.containsKey('imp-test'), isTrue);
    // Узел без адреса попадает в Направление по фильтру тега.
    expect(outboundByTag(cfg, 'vpn-1')['outbounds'], contains('imp-test'));
    expect(outboundByTag(cfg, 'vpn-1-auto')['outbounds'],
        contains('imp-test'));

    // impair под узлом: detour impair снят, detour Alpha → impair.
    await nodesHandler(
        req('PATCH', '/nodes/imp-test', body: {'detour': null}), ctx());
    await nodesHandler(
        req('PATCH', '/nodes/${Uri.encodeComponent(alpha)}',
            body: {'detour': 'imp-test'}),
        ctx());
    cfg = jsonDecode((await controller.generateConfig())!)
        as Map<String, dynamic>;
    expect(outboundByTag(cfg, alpha)['detour'], 'imp-test');
    expect(outboundByTag(cfg, 'imp-test').containsKey('detour'), isFalse);
  });

  test('подпись протокола impair в строке узла', () {
    expect(protoLabel('impair'), '☠ impair');
    expect(protoLabel('vless'), 'VLESS');
  });
}
