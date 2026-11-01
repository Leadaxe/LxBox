// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/mixins.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

/// §704 §7 — `/mixins/*`: CRUD, reorder, preview поверх реального хранилища.
void main() {
  late Directory tempDir;

  DebugContext ctx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 11, 1),
      );

  DebugRequest req(String method, String path, {Map<String, dynamic>? body}) =>
      DebugRequest.forTest(
        method: method,
        path: path,
        body: body == null ? const [] : utf8.encode(jsonEncode(body)),
      );

  Future<Map<String, dynamic>> call(String method, String path,
          {Map<String, dynamic>? body}) async =>
      (await mixinsHandler(req(method, path, body: body), ctx()) as JsonResponse)
          .body as Map<String, dynamic>;

  Future<List> list() async =>
      (await mixinsHandler(req('GET', '/mixins'), ctx()) as JsonResponse).body
          as List;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('mixins_handler_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    DebugRegistry.I.sub = null;
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  test('CRUD: create → get → patch → delete', () async {
    expect(await list(), isEmpty);
    final created = await mixinsHandler(
        req('POST', '/mixins', body: {
          'name': 'DNS listener',
          'target': 'inbounds',
          'op': 'append',
          'value': {'type': 'direct', 'tag': 'dns-in'},
        }),
        ctx()) as JsonResponse;
    expect(created.status, 201);
    final id = (created.body as Map)['id'] as String;
    expect(id, isNotEmpty);
    expect((created.body as Map)['enabled'], isTrue);

    expect((await call('GET', '/mixins/$id'))['target'], 'inbounds');

    final patched = await call('PATCH', '/mixins/$id',
        body: {'enabled': false, 'value': null});
    expect(patched['enabled'], isFalse);
    expect(patched['value'], isNull);
    expect(patched['name'], 'DNS listener');
    expect((await SettingsStorage.getMixins()).single.enabled, isFalse);

    final del = await call('DELETE', '/mixins/$id');
    expect(del['ok'], isTrue);
    expect(await list(), isEmpty);
    await expectLater(call('GET', '/mixins/$id'), throwsA(isA<NotFound>()));
  });

  test('валидация записи: синтаксис, глагол, remove, id', () async {
    Future<void> bad(Map<String, dynamic> body) => expectLater(
        call('POST', '/mixins', body: body), throwsA(isA<BadRequest>()));
    await bad({'target': 'a..b', 'op': 'set', 'value': 1});
    await bad({'target': 'log', 'op': 'patch', 'value': 1});
    await bad({'target': 'log', 'op': 'remove', 'value': 1});
    await bad({'op': 'set'});
    await bad({'id': 'x', 'target': 'log', 'op': 'set'});
    // Цели без совпадений принимаются — отказ виден на сборке.
    final ok = await call('POST', '/mixins',
        body: {'target': 'nope', 'op': 'remove', 'value': ['a']});
    await expectLater(call('PATCH', '/mixins/${ok['id']}', body: {'id': 'y'}),
        throwsA(isA<BadRequest>()));
    await expectLater(
        call('PATCH', '/mixins/${ok['id']}', body: {'op': 'nope'}),
        throwsA(isA<BadRequest>()));
  });

  test('reorder: ровно текущие id', () async {
    final a = await call('POST', '/mixins',
        body: {'target': 'log.level', 'op': 'set', 'value': 'warn'});
    final b = await call('POST', '/mixins',
        body: {'target': 'log.timestamp', 'op': 'remove', 'value': true});
    final r = await call('POST', '/mixins/reorder', body: {
      'order': [b['id'], a['id']],
    });
    expect(r['count'], 2);
    expect([for (final m in await list()) m['id']], [b['id'], a['id']]);
    await expectLater(
        call('POST', '/mixins/reorder', body: {
          'order': [a['id']],
        }),
        throwsA(isA<BadRequest>()));
  });

  test('preview: база до миксинов + миксины выше; без сборки — 409', () async {
    final a = await call('POST', '/mixins', body: {
      'target': 'inbounds',
      'op': 'append',
      'value': {'type': 'direct', 'tag': 'dns-in'},
    });
    final b = await call('POST', '/mixins', body: {
      'target': 'inbounds[tag=dns-in]',
      'op': 'merge',
      'value': {'listen_port': 5353},
    });
    final sub = SubscriptionController();
    DebugRegistry.I.sub = sub;
    await expectLater(
        call('GET', '/mixins/${b['id']}/preview'), throwsA(isA<Conflict>()));

    sub.debugSetLastConfigBeforeMixins({
      'inbounds': [
        {'type': 'tun', 'tag': 'tun-in'},
      ],
    });
    final p = await call('GET', '/mixins/${b['id']}/preview');
    expect(p['matches'], 1);
    expect(p['issue'], isNull);
    final frag = p['fragment'] as Map;
    expect(frag['parent_path'], 'inbounds');
    expect([for (final r in frag['rows'] as List) r['marker']], [' ', '~']);

    // Первый миксин на той же базе: дубль тега не появляется (миксин не
    // применён дважды).
    final pa = await call('GET', '/mixins/${a['id']}/preview');
    expect(pa['issue'], isNull);
    expect([for (final r in (pa['fragment'] as Map)['rows'] as List) r['marker']],
        [' ', '+']);

    final none = await call('POST', '/mixins',
        body: {'target': 'nope', 'op': 'set', 'value': 1});
    final pn = await call('GET', '/mixins/${none['id']}/preview');
    expect(pn['matches'], 0);
    expect((pn['issue'] as Map)['reason'], 'no match');
    expect(pn['fragment'], isNull);
    sub.dispose();
  });
}
