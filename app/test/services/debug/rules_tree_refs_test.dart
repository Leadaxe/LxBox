// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/rules.dart';
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

// §757 — живое хранение и Debug API: правило старой формы (`refs` на
// записи) читается деревом, PATCH и сохранение пишут `refs` в тело и не
// теряют ни ссылок, ни условий; правило с группами PATCH-ем плоских полей
// не портится.

const _a = 'https://example.com/rules/a.srs';
const _b = 'https://example.com/rules/b.srs';

void main() {
  late Directory tempDir;
  late DebugContext ctx;

  File mainFile() => File('${tempDir.path}/docs/lxbox_settings.json');
  Map<String, dynamic> onDisk() =>
      jsonDecode(mainFile().readAsStringSync()) as Map<String, dynamic>;
  Map<String, dynamic> recordOf(String id) => (onDisk()['rules'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((r) => r['id'] == id);

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('lxbox-rules-tree-refs');
    await Directory('${tempDir.path}/docs').create(recursive: true);
    await Directory('${tempDir.path}/support').create(recursive: true);
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    ctx = DebugContext(
      registry: DebugRegistry.I,
      appStartedAt: DateTime.utc(2026, 11, 23),
    );
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final res = await rulesHandler(
      DebugRequest.forTest(
        method: method,
        path: path,
        query: const {},
        body: body == null ? const [] : utf8.encode(jsonEncode(body)),
      ),
      ctx,
    );
    return (res as JsonResponse).body as Map<String, dynamic>;
  }

  test('хранение старой формы → GET → PATCH: refs в теле, условия целы',
      () async {
    mainFile().writeAsStringSync(jsonEncode({
      'storage_version': 1,
      'rules': [
        {
          'kind': 'srs',
          'id': 'r1',
          'name': 'S',
          'enabled': true,
          'num': 1000,
          'refs': [_a, _b],
          'body': {
            'port': [443],
            'outbound': 'direct-out',
          },
        },
      ],
    }));

    final rules = await SettingsStorage.getCustomRules();
    expect(rules.single.allRefs, [_a, _b]);

    final got = await call('GET', '/rules/r1');
    expect(got['srs_urls'], [_a, _b]);
    expect(got['ports'], ['443']);

    final patched = await call('PATCH', '/rules/r1', {
      'packages': ['com.x'],
    });
    expect(patched['srs_urls'], [_a, _b]);
    expect(patched['ports'], ['443']);
    expect(patched['packages'], ['com.x']);

    final rec = recordOf('r1');
    expect(rec.containsKey('refs'), isFalse);
    expect((rec['body'] as Map)['refs'], [_a, _b]);
    expect((rec['body'] as Map)['port'], [443]);

    SettingsStorage.resetCacheForTesting();
    final again = (await SettingsStorage.getCustomRules()).single;
    expect(again.allRefs, [_a, _b]);
    expect(again.packages, ['com.x']);
  });

  test('POST srs с srs_urls → запись с refs в теле', () async {
    final created = await call('POST', '/rules', {
      'kind': 'srs',
      'name': 'New',
      'srs_urls': [_a, _b],
      'ports': ['443'],
    });
    expect(created['srs_urls'], [_a, _b]);
    final rec = recordOf(created['id'] as String);
    expect(rec.containsKey('refs'), isFalse);
    expect((rec['body'] as Map)['refs'], [_a, _b]);
  });

  test('правило с группами: PATCH имени сохраняет дерево, плоское поле — 400',
      () async {
    mainFile().writeAsStringSync(jsonEncode({
      'storage_version': 1,
      'rules': [
        {
          'kind': 'srs',
          'id': 'g1',
          'name': 'G',
          'enabled': true,
          'num': 1000,
          'body': {
            'type': 'logical',
            'mode': 'or',
            'rules': [
              {
                'refs': [_a],
              },
              {
                'domain': ['example-5.com'],
              },
            ],
            'outbound': 'direct-out',
          },
        },
      ],
    }));
    final before = recordOf('g1')['body'];

    final renamed = await call('PATCH', '/rules/g1', {'name': 'G2'});
    expect(renamed['name'], 'G2');
    expect(renamed['srs_urls'], [_a]);
    expect(renamed['body'], before);
    expect(recordOf('g1')['body'], before);

    await expectLater(
      call('PATCH', '/rules/g1', {
        'ports': ['443'],
      }),
      throwsA(isA<BadRequest>()),
    );
    expect(recordOf('g1')['body'], before);
    final r = (await SettingsStorage.getCustomRules()).single;
    expect(r.allRefs, [_a]);
    expect(r.conditionValues('domain'), ['example-5.com']);
  });
}
