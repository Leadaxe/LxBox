// ignore_for_file: depend_on_referenced_packages

// Фича 478 / Д-1а — пути, которых не хватало для проверки страховки без
// экрана: `GET /nodes/link`, `GET /subs/{id}?warnings=true` и `raw` одиночного
// узла под `reveal=true`.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/nodes.dart';
import 'package:lxbox/services/debug/handlers/subs.dart';
import 'package:lxbox/services/debug/serializers/subs.dart';
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

void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе.
  setUpAll(loadEngineSections);

  late Directory tempDir;
  late SubscriptionController controller;

  const uri = 'vless://u1@h1.example:443?type=ws&security=tls#Alpha';

  DebugContext ctx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 9, 19),
      );

  DebugRequest req(
    String method,
    String path, {
    Map<String, String> query = const {},
  }) =>
      DebugRequest.forTest(
        method: method,
        path: path,
        query: query,
        body: const [],
      );

  Map<String, dynamic> asMap(DebugResponse r) =>
      (r as JsonResponse).body as Map<String, dynamic>;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('nodes_link_');
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

  group('GET /nodes/link', () {
    test('отдаёт ссылку того же emit, что Copy link', () async {
      await controller.addFromInput(uri);
      final tag = controller.entries.single.list.nodes.single.tag;

      final body = asMap(await nodesHandler(
        req('GET', '/nodes/link', query: {'tag': tag, 'reveal': 'true'}),
        ctx(),
      ));
      expect(body['tag'], tag);
      expect(body['protocol'], 'vless');
      expect(body['uri'], startsWith('vless://'));
      expect(body['private_key'], isFalse);
      // Тот же текст, что кладёт в буфер экран.
      expect(body['uri'], controller.entries.single.list.nodes.single.toUri());
    });

    test('без reveal — uri не отдаётся', () async {
      await controller.addFromInput(uri);
      final tag = controller.entries.single.list.nodes.single.tag;
      final body = asMap(
          await nodesHandler(req('GET', '/nodes/link', query: {'tag': tag}), ctx()));
      expect(body['error'], 'reveal required');
      expect(body.containsKey('uri'), isFalse);
    });

    test('тег с префиксом подписки тоже находится', () async {
      await controller.addFromInput(uri);
      final id = controller.entries.single.id;
      // Префикс ставим тем же путём, что и снаружи — через PATCH.
      await subsHandler(
        DebugRequest.forTest(
          method: 'PATCH',
          path: '/subs/$id',
          query: const {},
          body: utf8.encode(jsonEncode({'tag_prefix': 'vpn-1'})),
        ),
        ctx(),
      );
      final e = controller.entries.single;
      final node = e.list.nodes.single;
      expect(e.tagPrefix, 'vpn-1');
      // TagResolver склеивает префикс ПРОБЕЛОМ.
      final prefixed = '${e.tagPrefix} ${node.tag}';

      final body = asMap(await nodesHandler(
        req('GET', '/nodes/link', query: {'tag': prefixed, 'reveal': 'true'}),
        ctx(),
      ));
      expect(body['tag'], node.tag);
      expect(body['uri'], isNotEmpty);
    });

    test('без tag → 400, чужой тег → 404', () async {
      await controller.addFromInput(uri);
      await expectLater(
        nodesHandler(req('GET', '/nodes/link'), ctx()),
        throwsA(isA<BadRequest>()),
      );
      await expectLater(
        nodesHandler(req('GET', '/nodes/link', query: {'tag': 'nope'}), ctx()),
        throwsA(isA<NotFound>()),
      );
    });

    test('чужой путь и чужой метод — 404 / 400', () async {
      await expectLater(
        nodesHandler(req('GET', '/nodes/whatever'), ctx()),
        throwsA(isA<NotFound>()),
      );
      await expectLater(
        nodesHandler(req('POST', '/nodes/link', query: {'tag': 'x'}), ctx()),
        throwsA(isA<BadRequest>()),
      );
    });
  });

  group('GET /subs/{id}', () {
    test('reveal=true отдаёт raw одиночного узла, без него — нет', () async {
      await controller.addFromInput(uri);
      final id = controller.entries.single.id;

      final plain = asMap(await subsHandler(req('GET', '/subs/$id'), ctx()));
      expect(plain.containsKey('raw'), isFalse);

      final revealed = asMap(await subsHandler(
        req('GET', '/subs/$id', query: {'reveal': 'true'}),
        ctx(),
      ));
      expect(revealed['raw'], isNotEmpty);
      expect(revealed['raw'], contains('vless://'));
    });

    test('warnings=true — все узлы, origin_kind/source_kind, без флага нет',
        () async {
      await controller.addFromInput(uri);
      final id = controller.entries.single.id;
      final tag = controller.entries.single.list.nodes.single.tag;

      final plain = asMap(await subsHandler(req('GET', '/subs/$id'), ctx()));
      expect(plain.containsKey('warnings'), isFalse);
      expect(plain.containsKey('origin_kind'), isFalse);
      expect(plain.containsKey('source_kind'), isFalse);

      final withWarnings = asMap(await subsHandler(
        req('GET', '/subs/$id', query: {'warnings': 'true'}),
        ctx(),
      ));
      expect(withWarnings['origin_kind'], 'uri');
      expect(withWarnings['source_kind'], 'uri_lines');
      final map = withWarnings['warnings'] as Map<String, Object?>;
      expect(map.keys, contains(tag));
      expect(map[tag], isEmpty);
    });

  });

  // §520 — карта `warnings` ключевалась СЫРЫМ `NodeSpec.tag`, и у
  // узлов-тёзок (§310 — провайдер зовёт все узлы `proxy`; дубль
  // `vpn://`↔`amneziawg://` под одним именем) записи затирали друг друга
  // last-write-wins: предупреждения ранних дублей молча пропадали, ответ
  // отдавал меньше ключей, чем `nodes_count`. Ключ — сырой тег узла в
  // контейнере (`containerRawTags`, NODE_LINK §2.2): тот же адрес, что у
  // `nodes[]`, `/nodes/link?tag=` и `switch-node`.
  group('serializeEntryWarnings — тёзки не затирают друг друга (§520)', () {
    // Синтетика, а не URI-конвейер: через какой ввод разбор выдаст ИМЕННО
    // трёх тёзок с разными кодами — вопрос конвейера, а пиним мы здесь
    // ключевание ответа.
    VlessSpec node(String id, String tag, List<NodeWarning> warnings) =>
        VlessSpec(
          id: id,
          tag: tag,
          label: tag,
          server: '$id.example',
          port: 443,
          rawSource: 'vless://u@$id.example:443#$tag',
          uuid: 'ffffffff-ffff-ffff-ffff-ffffffffffff',
          warnings: warnings,
        );

    test('3 узла с одним сырым тегом → 3 ключа, все предупреждения на месте',
        () {
      final entry = SubscriptionEntry(
        list: SubscriptionServers(
          id: 'sub-520',
          name: 'Twins',
          enabled: true,
          tagPrefix: '',
          detourPolicy: const DetourPolicy(),
          url: 'https://provider.example/sub',
          nodes: [
            node('n1', 'proxy', const [
              RegistryWarning(
                  code: 'reality_fp_not_chrome',
                  path: 'tls.utls.fingerprint',
                  value: 'safari'),
            ]),
            node('n2', 'proxy', const [
              RegistryWarning(code: 'awg_header_invalid', path: 'h1', value: 'abc'),
            ]),
            node('n3', 'proxy', const [SectionsConflictWarning()]),
          ],
        ),
      );

      final map = serializeEntryWarnings(entry);

      // Раньше здесь был ОДИН ключ `proxy` с предупреждениями последнего узла.
      expect(map.length, 3);
      // Первый тёзка держит дословный тег, следующие — уникализация источника
      // (`X`, `X-2`, `X-3`), ровно как в `nodes[]` и у `switch-node`.
      expect(map.keys.toList(), ['proxy', 'proxy-2', 'proxy-3']);

      List<Map<String, Object?>> at(String key) =>
          (map[key] as List).cast<Map<String, Object?>>();

      expect(at('proxy').single['code'], 'reality_fp_not_chrome');
      expect(at('proxy-2').single['code'], 'awg_header_invalid');
      // Класс приложения: кода нет, текст есть.
      expect(at('proxy-3').single['code'], isNull);
      expect(at('proxy-3').single['text_en'], contains('sections'));
    });

    test('nodes_count == warnings.length при тёзках (вход с 2 тёзками)', () {
      // Вход с двумя тёзками: 4 узла, из них двое зовутся одинаково.
      final entry = SubscriptionEntry(
        list: SubscriptionServers(
          id: 'sub-520-d',
          name: 'Entry D',
          enabled: true,
          tagPrefix: '',
          detourPolicy: const DetourPolicy(),
          url: 'https://provider.example/d',
          nodes: [
            node('d1', 'Frankfurt', const []),
            node('d2', 'Tokyo', const [
              RegistryWarning(code: 'awg_header_invalid', path: 'h2', value: 'x'),
            ]),
            node('d3', 'Tokyo', const [SectionsConflictWarning()]),
            node('d4', 'Amsterdam', const []),
          ],
        ),
        // Как его ставит контроллер на разборе выдачи
        // (`entry.nodeCount = nodes.length`): по умолчанию у подписки
        // счётчик берётся из `lastNodeCount` хранения, а не из тела.
        nodeCount: 4,
      );

      final body = {
        ...serializeSubEntry(entry, reveal: false),
        'warnings': serializeEntryWarnings(entry),
      };
      final map = body['warnings'] as Map<String, Object?>;

      // Счётчик и список больше не расходятся — это и был симптом §520.
      expect(body['nodes_count'], 4);
      expect(map.length, 4);
      expect(map.keys.toList(),
          ['Frankfurt', 'Tokyo', 'Tokyo-2', 'Amsterdam']);
      // Узел без предупреждений всё ещё присутствует пустым списком.
      expect(map['Frankfurt'], isEmpty);
      expect(map['Amsterdam'], isEmpty);
      // Оба тёзки сохранили СВОИ предупреждения.
      expect((map['Tokyo'] as List).single, isA<Map<String, Object?>>());
      expect(((map['Tokyo'] as List).single as Map)['code'],
          'awg_header_invalid');
      expect(((map['Tokyo-2'] as List).single as Map)['code'], isNull);
    });

    test('запись без тёзок: ключи дословно равны сырым тегам', () {
      final entry = SubscriptionEntry(
        list: SubscriptionServers(
          id: 'sub-520-uniq',
          name: 'Uniq',
          enabled: true,
          tagPrefix: '',
          detourPolicy: const DetourPolicy(),
          url: 'https://provider.example/u',
          nodes: [
            node('u1', '🇩🇪 Frankfurt', const []),
            node('u2', 'Tokyo', const []),
          ],
        ),
      );
      // Обратная совместимость формы: без тёзок ответ не двигается вовсе.
      expect(serializeEntryWarnings(entry).keys.toList(),
          ['🇩🇪 Frankfurt', 'Tokyo']);
    });
  });

  // Форма записи пинится прямо на сериализаторе: через какой URI разбор
  // выдаст предупреждение — вопрос конвейера, а проверяем мы здесь ответ.
  // Оба вида идут через общий интерфейс NodeWarning, поэтому перевод классов
  // на RegistryWarning форму не двигает.
  group('serializeNodeWarning — форма ответа', () {
    test('код реестра: code, path, value и оба текста', () {
      final j = serializeNodeWarning(const RegistryWarning(
        code: 'reality_fp_not_chrome',
        path: 'tls.utls.fingerprint',
        value: 'safari',
      ));
      expect(j['code'], 'reality_fp_not_chrome');
      expect(j['path'], 'tls.utls.fingerprint');
      expect(j['value'], 'safari');
      expect(j['severity'], anyOf('info', 'warning', 'error'));
      expect(j['title_en'], isA<String>());
      expect(j['text_en'], isA<String>());
      expect(j['text_en'] as String, isNotEmpty);
    });

    // Д-2 (эмулятор 19.09.2026) — заголовок зовёт `{path}`, а сериализатор
    // передавал одни `params`: в ответ уезжал сам плейсхолдер.
    test('awg_header_invalid: в title_en подставлен path, {…} не осталось',
        () {
      final j = serializeNodeWarning(const RegistryWarning(
        code: 'awg_header_invalid',
        path: 'h1',
        value: 'abc',
      ));
      final title = j['title_en'] as String;
      expect(title, contains('h1'));
      expect(title, isNot(contains('{')));
      expect(j['text_en'] as String, isNot(contains('{')));
    });

    test('класс приложения: кода нет, text_en есть', () {
      final j = serializeNodeWarning(const SectionsConflictWarning());
      expect(j['code'], isNull);
      expect(j['path'], isNull);
      expect(j['value'], isNull);
      expect(j['title_en'], isNull);
      // Пиненный английский самого класса — ответ не зависит от локали.
      expect(j['text_en'], contains('sections'));
      expect(j['severity'], 'warning');
    });
  });
}
