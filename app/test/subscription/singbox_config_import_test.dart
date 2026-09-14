// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/http_cache.dart';
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

/// §368 — импорт sing-box JSON через контроллер: какой контейнер получается.
///
/// Порог тот же, что у файлового импорта (§129): один узел — сервер
/// (`UserServer`), несколько — набор (файловая подписка). `UserServer` устроен
/// как «один сервер», и конфиг на десяток узлов с группой в него не помещается.
void main() {
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

    test('полный конфиг → файловая подписка, а не UserServer', () async {
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

    test('массив outbound\'ов → одна запись со всеми узлами', () async {
      final c = SubscriptionController();
      await c.addFromInput('['
          '{"type":"vless","tag":"a","server":"a.example",'
          '"server_port":443,"uuid":"u-a"},'
          '{"type":"vless","tag":"b","server":"b.example",'
          '"server_port":443,"uuid":"u-b"}'
          ']');
      expect(c.lastError, isNull);
      // Раньше массив раскладывался по записи на элемент («v1 parity»).
      expect(c.entries, hasLength(1));
      expect(c.entries.single.list.nodes, hasLength(2));
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

    test('endpoint + прокси → два UserServer, связка у ts', () async {
      final c = SubscriptionController();
      await c.addFromInput(
          '{"endpoints":[$tsEndpoint],"outbounds":[$proxy],'
          '"route":{"final":"DE"}}');
      expect(c.lastError, isNull);
      expect(c.entries, hasLength(2));

      final tsEntry = c.entries.firstWhere(
          (e) => e.list.nodes.single is TailscaleSpec);
      final tsList = tsEntry.list as UserServer;
      // Связка канонична: ссылок на тег в конфиге не было.
      expect(tsList.sections!.recordCount, 3);
      expect(tsList.sections!.rules.single.name, '@{self} network');
      expect(tsList.sections!.rules.single.domainSuffixes, ['.ts.net']);

      // Остаток — один узел, значит свой UserServer, а не файловая подписка.
      final rest = c.entries.firstWhere((e) => e != tsEntry);
      expect(rest.list, isA<UserServer>());
      expect(rest.list.nodes.single.label, 'DE');
      expect((rest.list as UserServer).sections, isNull);
    });

    test('endpoint + два прокси → UserServer (ts) + файловая подписка без ts '
        'в кэше', () async {
      final c = SubscriptionController();
      await c.addFromInput(
          '{"endpoints":[$tsEndpoint],"outbounds":[$proxy,$proxy2]}');
      expect(c.lastError, isNull);
      expect(c.entries, hasLength(2));

      final tsList = c.entries
          .map((e) => e.list)
          .whereType<UserServer>()
          .single;
      expect(tsList.nodes.single, isA<TailscaleSpec>());
      expect(tsList.sections!.recordCount, 3);

      final sub = c.entries
          .map((e) => e.list)
          .whereType<SubscriptionServers>()
          .single;
      expect(sub.nodes.map((n) => n.label), ['DE', 'NL']);
      // Кэш файловой подписки перечитывается на старте — tailscale обязан
      // из него исчезнуть, иначе узел вернулся бы дублем.
      final cached = await HttpCache.loadBody(sub.url);
      expect(cached, isNotNull);
      expect(cached, isNot(contains('tailscale')));
      expect(cached, contains('"DE"'));
      expect(cached, contains('"NL"'));
    });

    test('endpoint + группа: остаток без узлов — не ошибка', () async {
      final c = SubscriptionController();
      await c.addFromInput('{"endpoints":[$tsEndpoint],"outbounds":['
          '{"type":"selector","tag":"sel","outbounds":["home-ts"]}]}');
      expect(c.lastError, isNull);
      final list = c.entries.single.list as UserServer;
      expect(list.nodes.single, isA<TailscaleSpec>());
      expect(list.sections!.recordCount, 3);
    });

    test('многоузловой конфиг со ссылками: у ts извлечённая связка', () async {
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
      // Извлечённое сильнее канонического: имя провайдера, один CIDR.
      expect(tsList.sections!.rules.single.name, '@{self} rule 1');
      expect(tsList.sections!.rules.single.ipCidrs, ['100.64.0.0/10']);
      expect(tsList.sections!.dnsServers.single.tag, '@{self}-ts-dns');
    });

    test('голое тело → каноническая связка', () async {
      final c = SubscriptionController();
      await c.addFromInput(tsEndpoint);
      expect(c.lastError, isNull);
      final list = c.entries.single.list as UserServer;
      expect(list.sections!.recordCount, 3);
      expect(list.sections!.rules.single.ipCidrs,
          ['100.64.0.0/10', 'fd7a:115c:a1e0::/48']);
    });

    test('конфиг с одним ts без ссылок → каноническая связка', () async {
      final c = SubscriptionController();
      await c.addFromInput('{"endpoints":[$tsEndpoint],'
          '"route":{"rules":[{"domain":["x"],"outbound":"direct"}]}}');
      expect(c.lastError, isNull);
      final list = c.entries.single.list as UserServer;
      expect(list.sections!.recordCount, 3);
      expect(list.sections!.rules.single.name, '@{self} network');
    });

    test('папка: голое тело членом → каноническая связка', () async {
      final c = SubscriptionController();
      await c.addFolder('tailnet');
      expect(await c.addMembersToFolder(0, tsEndpoint), isNull);
      final folder = c.entries.single.list as FolderServers;
      expect(folder.members.single.sections!.recordCount, 3);
      expect(folder.members.single.sections!.rules.single.name,
          '@{self} network');
    });

    test('не-Tailscale узел секций по умолчанию не получает', () async {
      final c = SubscriptionController();
      await c.addFromInput(singleOutbound);
      expect((c.entries.single.list as UserServer).sections, isNull);
    });
  });
}
