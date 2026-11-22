// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/services/rule_set_downloader.dart';
import 'package:lxbox/services/storage_migration/rule_set_cache_ids.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// §757 (спека §6) — миграция файлов кэша наборов с позиционного id
// (`<id>`, `<id>~<номер>`) на id по ссылке (`<id>~<h8>`).

void main() {
  late Directory tempDir;
  late Directory cache;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('rs_cache_ids_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    RuleSetDownloader.resetCacheForTesting();
    cache = Directory('${tempDir.path}/rule_sets')..createSync(recursive: true);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  File srs(String id) => File('${cache.path}/$id.srs');
  File meta(String id) => File('${cache.path}/$id.meta.json');

  const a = 'https://example.com/rules/a.srs';
  const b = 'https://example.com/rules/b.srs';
  final rule = CustomRuleTree.flat(
    id: 'r1',
    name: 'R',
    srsUrls: const [a, b],
    outbound: 'direct-out',
  );

  test('файлы и метаданные переименовываются по ссылкам в прежнем порядке',
      () async {
    srs('r1').writeAsStringSync('A');
    meta('r1').writeAsStringSync('{"etag":"a"}');
    srs('r1~1').writeAsStringSync('B');
    meta('r1~1').writeAsStringSync('{"etag":"b"}');

    expect(await migrateRuleSetCacheIds([rule]), 2);

    final idA = CustomRuleTree.cacheIdFor('r1', a);
    final idB = CustomRuleTree.cacheIdFor('r1', b);
    expect(rule.cacheIds, [idA, idB]);
    expect(srs(idA).readAsStringSync(), 'A');
    expect(meta(idA).readAsStringSync(), '{"etag":"a"}');
    expect(srs(idB).readAsStringSync(), 'B');
    expect(meta(idB).readAsStringSync(), '{"etag":"b"}');
    expect(srs('r1').existsSync(), isFalse);
    expect(meta('r1').existsSync(), isFalse);
    expect(srs('r1~1').existsSync(), isFalse);
    expect(meta('r1~1').existsSync(), isFalse);
  });

  test('повторный запуск ничего не делает', () async {
    srs('r1').writeAsStringSync('A');
    srs('r1~1').writeAsStringSync('B');
    expect(await migrateRuleSetCacheIds([rule]), 2);
    final before = {
      for (final f in cache.listSync().whereType<File>())
        f.uri.pathSegments.last: f.readAsStringSync(),
    };
    expect(await migrateRuleSetCacheIds([rule]), 0);
    final after = {
      for (final f in cache.listSync().whereType<File>())
        f.uri.pathSegments.last: f.readAsStringSync(),
    };
    expect(after, before);
  });

  test('отсутствующий файл не ломает; файл под новым именем не трогается',
      () async {
    final idA = CustomRuleTree.cacheIdFor('r1', a);
    // Первого старого файла нет вовсе; у второй ссылки уже есть новый файл,
    // а старый остался рядом (прерванная миграция) — новый не затирается.
    srs(CustomRuleTree.cacheIdFor('r1', b)).writeAsStringSync('new');
    srs('r1~1').writeAsStringSync('old');

    expect(await migrateRuleSetCacheIds([rule]), 0);
    expect(srs(idA).existsSync(), isFalse);
    expect(
      srs(CustomRuleTree.cacheIdFor('r1', b)).readAsStringSync(),
      'new',
    );
  });

  test('правила без ссылок и не-дерево пропускаются', () async {
    final inline = CustomRuleTree.flat(
      id: 'r2',
      name: 'I',
      domains: const ['a.com'],
    );
    srs('r2').writeAsStringSync('x');
    expect(
      await migrateRuleSetCacheIds([
        inline,
        CustomRuleJson(id: 'r3', name: 'J', json: '{}'),
      ]),
      0,
    );
    expect(srs('r2').existsSync(), isTrue);
  });
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tempRoot);
  final String tempRoot;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempRoot;
}
