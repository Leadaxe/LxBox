// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_dialect.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

/// §368 / §722 — импорт sing-box JSON через контроллер: какой контейнер
/// получается.
///
/// §722 (контракт 1.1.165, §11 п.2) — массив режется на записи (по записи на
/// элемент), документ — одна своя запись целиком, обрезанная до узловых
/// массивов. Конфиг с группами (`selector`/`urltest`) своей записью не
/// выражается и приезжает файловой подпиской (§129).
void main() {
  // Xray разбирается только движком по секциям реестра (запасного
  // рукописного пути нет, спека 480 крит. 7): без загрузки документ Xray
  // запасной классификатор отдаёт ветке sing-box — `protocol_unsupported`.
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  late Directory tempDir;

  const singleOutbound = '{"type":"vless","tag":"solo",'
      '"server":"a.example","server_port":443,"uuid":"u-1"}';

  const wholeConfig = '''
{
  "log": {"level": "info"},
  "dns": {"servers": [{"tag": "g", "address": "8.8.8.8"}]},
  "inbounds": [{"type": "tun", "tag": "tun-in"}],
  "outbounds": [
    {"type": "vless", "tag": "DE", "server": "de.example", "server_port": 443,
     "uuid": "u-de", "detour": "jump"},
    {"type": "trojan", "tag": "NL", "server": "nl.example", "server_port": 443,
     "password": "p-nl"},
    {"type": "shadowsocks", "tag": "jump", "server": "jump.example",
     "server_port": 8388, "method": "aes-256-gcm", "password": "p-j"},
    {"type": "urltest", "tag": "Fastest", "outbounds": ["DE", "NL"]},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"rules": [{"protocol": "dns", "outbound": "dns-out"}]}
}
''';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('sb_import_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  group('§368 контейнер по числу узлов', () {
    test('одиночный outbound → UserServer (как было)', () async {
      final c = SubscriptionController();
      await c.addFromInput(singleOutbound);
      expect(c.lastError, isNull);
      final entry = c.entries.single;
      expect(entry.list, isA<UserServer>());
      expect(entry.list.nodes, hasLength(1));
    });

    test('полный конфиг с группой → файловая подписка, а не UserServer',
        () async {
      final c = SubscriptionController();
      await c.addFromInput(wholeConfig);
      expect(c.lastError, isNull);

      final entry = c.entries.single;
      expect(entry.list, isA<SubscriptionServers>());
      final sub = entry.list as SubscriptionServers;
      // Файловая форма §129: свой url + авто-обновление выключено.
      expect(sub.url, startsWith('file:'));
      expect(sub.updateIntervalHours, -1);
    });

    test('конфиг: узлы, группа и цепочка доехали', () async {
      final c = SubscriptionController();
      await c.addFromInput(wholeConfig);

      final nodes = c.entries.single.list.nodes;
      // DE + NL + группа. `jump` — звено DE, служебный `direct` не в счёт.
      expect(nodes, hasLength(3));

      final de = nodes.firstWhere((n) => n.label == 'DE');
      expect(de.chained?.server, 'jump.example');

      final group = nodes.firstWhere((n) => n.isGroup);
      expect(group, isA<AutoSelectSpec>());
      expect(group.label, 'Fastest');
    });

    // §722 — массив — форма ввода: по своей записи на элемент, вид у каждой.
    test('массив из 3 outbound\'ов → 3 записи', () async {
      final c = SubscriptionController();
      await c.addFromInput('['
          '{"type":"vless","tag":"a","server":"a.example",'
          '"server_port":443,"uuid":"u-a"},'
          '{"type":"vless","tag":"b","server":"b.example",'
          '"server_port":443,"uuid":"u-b"},'
          '{"type":"vless","tag":"c","server":"c.example",'
          '"server_port":443,"uuid":"u-c"}'
          ']');
      expect(c.lastError, isNull);
      expect(c.entries, hasLength(3));
      for (final e in c.entries) {
        final u = e.list as UserServer;
        expect(u.nodes, hasLength(1));
        expect(u.dialect, SourceDialect.singbox);
        expect(sourceKindOf(u.rawBody), 'singbox_outbound');
      }
    });

    // §722 — документ без групп: одна запись целиком, все узлы записи.
    test('документ из двух узлов без групп → одна запись, route снят',
        () async {
      final c = SubscriptionController();
      await c.addFromInput('{"outbounds":['
          '{"type":"vless","tag":"a","server":"a.example",'
          '"server_port":443,"uuid":"u-a"},'
          '{"type":"vless","tag":"b","server":"b.example",'
          '"server_port":443,"uuid":"u-b"}'
          '],"route":{"final":"a"}}');
      expect(c.lastError, isNull);
      final u = c.entries.single.list as UserServer;
      expect(u.dialect, SourceDialect.singbox);
      expect(u.nodes, hasLength(2));
      expect(u.rawBody, isNot(contains('route')));
    });

    // §722 — Xray-конфиг своей записью: вид xray, текст Xray, без routing.
    test('Xray-конфиг → одна запись вида xray', () async {
      final c = SubscriptionController();
      await c.addFromInput('{"outbounds":[{"tag":"xr","protocol":"vless",'
          '"settings":{"vnext":[{"address":"example-1.com","port":443,'
          '"users":[{"id":"11111111-2222-3333-4444-555555555555",'
          '"encryption":"none"}]}]},'
          '"streamSettings":{"network":"tcp","security":"none"}}],'
          '"routing":{"rules":[]}}');
      expect(c.lastError, isNull);
      final u = c.entries.single.list as UserServer;
      expect(u.dialect, SourceDialect.xray);
      expect(u.rawBody, contains('"protocol"'));
      expect(u.rawBody, isNot(contains('routing')));
    });

    // §722 «Проверка» п.2 — Xray-конфиг с цепочкой `dialerProxy`: одна запись
    // вида xray, узлы записи — владелец и звено.
    test('Xray-конфиг с dialerProxy → одна запись, два узла', () async {
      final c = SubscriptionController();
      await c.addFromInput('{"outbounds":['
          '{"tag":"main","protocol":"vless",'
          '"settings":{"vnext":[{"address":"example-1.com","port":443,'
          '"users":[{"id":"11111111-2222-3333-4444-555555555555",'
          '"encryption":"none"}]}]},'
          '"streamSettings":{"network":"tcp","security":"none",'
          '"sockopt":{"dialerProxy":"relay"}}},'
          '{"tag":"relay","protocol":"vless",'
          '"settings":{"vnext":[{"address":"example-2.com","port":443,'
          '"users":[{"id":"11111111-2222-3333-4444-555555555556",'
          '"encryption":"none"}]}]},'
          '"streamSettings":{"network":"tcp","security":"none"}}],'
          '"routing":{"rules":[]}}');
      expect(c.lastError, isNull);
      final u = c.entries.single.list as UserServer;
      expect(u.dialect, SourceDialect.xray);
      expect(recordNodesOf(u.nodes), hasLength(2));
      expect(u.rawBody, contains('dialerProxy'));
      expect(u.rawBody, isNot(contains('routing')));
    });

    test('не-JSON → ошибка «не распознано», записей нет', () async {
      final c = SubscriptionController();
      await c.addFromInput('это не конфиг');
      expect(c.lastError, isNotNull);
      expect(c.entries, isEmpty);
    });

    test('JSON без пригодных outbound\'ов → своя ошибка, не «не распознано»',
        () async {
      final c = SubscriptionController();
      await c.addFromInput('{"outbounds":[{"type":"direct","tag":"d"}]}');
      expect(c.lastError, isNotNull);
      expect(c.lastError!.renderEn(),
          contains('No valid outbounds'));
      expect(c.entries, isEmpty);
    });
  });

  group('§437 Tailscale в многоузловой вставке', () {
    const tsEndpoint = '{"type":"tailscale","tag":"home-ts",'
        '"auth_key":"tskey-auth-xxx"}';
    const proxy = '{"type":"vless","tag":"DE","server":"de.example",'
        '"server_port":443,"uuid":"u-de"}';
    const proxy2 = '{"type":"trojan","tag":"NL","server":"nl.example",'
        '"server_port":443,"password":"p-nl"}';

    // §575 — секции узла упразднены: ни извлечённой, ни канонической связки
    // узел не получает, её даёт пресет шаблона `tailscale` (§578).
    test('endpoint + прокси → два UserServer, секций нет', () async {
      final c = SubscriptionController();
      await c.addFromInput(
          '{"endpoints":[$tsEndpoint],"outbounds":[$proxy],'
          '"route":{"final":"DE"}}');
      expect(c.lastError, isNull);
      expect(c.entries, hasLength(2));

      final tsEntry = c.entries.firstWhere(
          (e) => e.list.nodes.single is TailscaleSpec);
      expect(tsEntry.list, isA<UserServer>());

      // Остаток — один узел, значит свой UserServer, а не файловая подписка.
      final rest = c.entries.firstWhere((e) => e != tsEntry);
      expect(rest.list, isA<UserServer>());
      // §722 — в источнике документ, обрезанный до узловых массивов;
      // дефолтный эмодзи ставится узлу-владельцу, а не в корень документа.
      expect(rest.list.nodes.single.label, '⚡ DE');
      final restRaw = (rest.list as UserServer).rawBody;
      expect(sourceKindOf(restRaw), 'singbox_config');
      expect(restRaw, isNot(contains('route')));
    });

    // §722 — остаток без tailscale — документ из двух узлов без групп: одна
    // своя запись целиком (раньше — файловая подписка).
    test('endpoint + два прокси → UserServer (ts) + запись остатка без ts',
        () async {
      final c = SubscriptionController();
      await c.addFromInput(
          '{"endpoints":[$tsEndpoint],"outbounds":[$proxy,$proxy2]}');
      expect(c.lastError, isNull);
      expect(c.entries, hasLength(2));

      final lists = c.entries.map((e) => e.list).whereType<UserServer>();
      expect(lists, hasLength(2));
      final tsList = lists.firstWhere((l) => l.nodes.first is TailscaleSpec);
      expect(tsList.nodes.single, isA<TailscaleSpec>());

      // Источник остатка — документ без tailscale: иначе узел вернулся бы
      // дублем при перечитывании записи.
      final rest = lists.firstWhere((l) => l != tsList);
      expect(rest.nodes, hasLength(2));
      expect(rest.nodes.last.label, 'NL');
      expect(rest.rawBody, isNot(contains('tailscale')));
      expect(rest.rawBody, contains('"NL"'));
    });

    test('endpoint + группа: остаток без узлов — не ошибка', () async {
      final c = SubscriptionController();
      await c.addFromInput('{"endpoints":[$tsEndpoint],"outbounds":['
          '{"type":"selector","tag":"sel","outbounds":["home-ts"]}]}');
      expect(c.lastError, isNull);
      final list = c.entries.single.list as UserServer;
      expect(list.nodes.single, isA<TailscaleSpec>());
    });

    test('многоузловой конфиг со ссылками: связка не извлекается', () async {
      final c = SubscriptionController();
      await c.addFromInput('''
{
  "endpoints": [$tsEndpoint],
  "outbounds": [$proxy],
  "dns": {"servers": [
    {"type": "tailscale", "tag": "ts-dns", "endpoint": "home-ts"}
  ], "rules": [{"domain_suffix": [".ts.net"], "server": "ts-dns"}]},
  "route": {"rules": [
    {"ip_cidr": ["100.64.0.0/10"], "outbound": "home-ts"}
  ], "final": "DE"}
}
''');
      expect(c.lastError, isNull);
      final tsList = c.entries
          .map((e) => e.list)
          .whereType<UserServer>()
          .firstWhere((l) => l.nodes.single is TailscaleSpec);
      expect(tsList.nodes.single, isA<TailscaleSpec>());
    });

    test('голое тело → узел без секций', () async {
      final c = SubscriptionController();
      await c.addFromInput(tsEndpoint);
      expect(c.lastError, isNull);
      final list = c.entries.single.list as UserServer;
      expect(list.nodes.single, isA<TailscaleSpec>());
    });

    test('конфиг с одним ts и route → узел без секций', () async {
      final c = SubscriptionController();
      await c.addFromInput('{"endpoints":[$tsEndpoint],'
          '"route":{"rules":[{"domain":["x"],"outbound":"direct"}]}}');
      expect(c.lastError, isNull);
      expect(c.entries.single.list, isA<UserServer>());
    });

    test('папка: голое тело членом → секций нет', () async {
      final c = SubscriptionController();
      await c.addFolder('tailnet');
      expect(await c.addMembersToFolder(0, tsEndpoint), isNull);
      final folder = c.entries.single.list as FolderServers;
      expect(folder.members.single.node, isA<TailscaleSpec>());
    });
  });
}
