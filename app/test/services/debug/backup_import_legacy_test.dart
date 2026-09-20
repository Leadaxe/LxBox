// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/backup.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../../parser/engine_test_setup.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$root/docs';
}

/// §439 §3.4 / §3.5 — Debug `/backup/*` и форма хранения 2.23.2:
/// `POST /backup/import` принимает блок `storage` без `storage_version`,
/// мигрирует его и называет это в ответе; `GET /backup/export?from=v0_bak`
/// отдаёт исходник первой миграции.
void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

  late Directory tmp;

  DebugContext ctx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 9, 15),
      );

  File settingsFile() => File('${tmp.path}/docs/lxbox_settings.json');

  Map<String, dynamic> readFile() =>
      jsonDecode(settingsFile().readAsStringSync()) as Map<String, dynamic>;

  Map<String, dynamic> body(DebugResponse r) =>
      (r as JsonResponse).body as Map<String, dynamic>;

  /// Блок `storage`, каким его отдавал `GET /backup/export` версии 2.23.2.
  Map<String, dynamic> legacyStorage() => {
        'vars': {'log_level': 'warn'},
        'server_lists': [
          {
            'type': 'subscription',
            'id': 'sub-1',
            'name': 'Provider',
            'enabled': true,
            'tag_prefix': 'PR',
            'url': 'https://example.com/sub/1',
            'update_interval_hours': 12,
          },
          {
            'type': 'user',
            'id': 'srv-1',
            'name': '',
            'enabled': true,
            'raw_body': 'vless://11111111-1111-1111-1111-111111111111'
                '@198.51.100.1:443?type=ws&security=tls#Tokyo',
          },
        ],
        'chains': [
          {
            'tag': 'chain-1',
            'hops': ['Tokyo', 'vpn-1'],
            'order': 7,
          },
        ],
        'custom_rules': [
          {
            'id': 'r1',
            'name': 'Ads',
            'enabled': true,
            'kind': 'inline',
            'num': 1000,
            'domainSuffixes': ['ads.example'],
            'outbound': 'reject',
          },
          {
            'id': 'r2',
            'name': 'Raw',
            'enabled': true,
            'kind': 'json',
            'num': 1001,
            'json': '[{"action":"sniff"},{"action":"hijack-dns","port":53}]',
          },
        ],
        'dns_options': {
          'servers': [
            {
              'enabled': true,
              'kind': 'inline',
              'tag': 'my-doh',
              'body': {'type': 'https', 'server': 'dns.example'},
            },
            {
              'enabled': true,
              'kind': 'template',
              'tag': 'google_doh',
              'varValues': {'outbound': 'vpn-1'},
            },
          ],
          'rules': [
            {
              'kind': 'inline',
              'name': 'corp',
              'rule': {
                'domain_suffix': ['.corp'],
                'server': 'my-doh',
              },
            },
          ],
          'rules_json': '[]',
        },
        'directions': [
          {'tag': 'vpn-1', 'label': 'Main', 'enabled': true},
        ],
        'directions_migrated': true,
        'excluded_nodes': ['x'],
        'show_detour_servers': true,
      };

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('backup_import_legacy_');
    await Directory('${tmp.path}/docs').create();
    await Directory('${tmp.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    SettingsStorage.resetCacheForTesting();
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  test('POST /backup/import: блок без storage_version мигрирует, '
      'applied.migrated и отчёт в ответе', () async {
    final r = await backupHandler(
      DebugRequest.forTest(
        method: 'POST',
        path: '/backup/import',
        body: utf8.encode(jsonEncode({'storage': legacyStorage()})),
      ),
      ctx(),
    );
    final applied = body(r)['applied'] as Map<String, dynamic>;
    expect(applied['migrated'], isTrue);
    final report = applied['migration'] as Map<String, dynamic>;
    expect(report['migrated'], isTrue);
    expect(report.containsKey('found_version'), isFalse);
    expect((report['info'] as List).join('\n'),
        allOf(contains('1 subscriptions'), contains('1 chains'),
            contains('"Raw" → 2'), contains('excluded_nodes')));
    expect(applied.containsKey('dropped_keys'), isFalse,
        reason: 'мёртвые ключи снимает миграция, а не allowlist');

    // На диске — форма 1.0 без ключей 2.23.2.
    final file = readFile();
    expect(file['storage_version'], 1);
    for (final k in [
      'server_lists',
      'chains',
      'custom_rules',
      'dns_options',
      'excluded_nodes',
      'show_detour_servers',
    ]) {
      expect(file.containsKey(k), isFalse, reason: k);
    }
    expect((file['sources'] as List).map((s) => (s as Map)['kind']),
        ['subscription', 'server', 'chain']);

    // Модели читают то же, что было в архиве.
    final lists = await SettingsStorage.getServerLists();
    expect((lists[0] as SubscriptionServers).tagPrefix, 'PR');
    expect((lists[0] as SubscriptionServers).updateIntervalHours, 12);
    expect(lists[1].nodes.single.tag, 'Tokyo');
    expect((await SettingsStorage.getChains()).single.hops, const [NodeLink(tag: 'Tokyo'), NodeLink(tag: 'vpn-1')]);
    final rules = await SettingsStorage.getCustomRules();
    expect(rules.map((x) => x.name), ['Ads', 'Raw', 'Raw #2']);
    expect(rules.map((x) => x.orderNum), [1000, 1001, 1001]);
    expect(rules[0].outbound, kOutboundReject);
    final servers = await SettingsStorage.getDnsServers();
    expect((servers[1] as DnsServerTemplate).varValues, {'outbound': 'vpn-1'});
    expect(
        (await SettingsStorage.getDnsRulesList()).single, isA<DnsRuleInline>());
  });

  test('POST /backup/import: блок формы 1.0 — migrated: false, отчёта нет',
      () async {
    final r = await backupHandler(
      DebugRequest.forTest(
        method: 'POST',
        path: '/backup/import',
        body: utf8.encode(jsonEncode({
          'storage': {
            'storage_version': 1,
            'vars': {'log_level': 'warn'},
            'rules': [],
          },
        })),
      ),
      ctx(),
    );
    final applied = body(r)['applied'] as Map<String, dynamic>;
    expect(applied['migrated'], isFalse);
    expect(applied.containsKey('migration'), isFalse);
  });

  test('GET /backup/export?from=v0_bak: исходник первой миграции; без копии — '
      '404', () async {
    Future<DebugResponse> export(Map<String, String> query) => backupHandler(
          DebugRequest.forTest(
              method: 'GET', path: '/backup/export', query: query),
          ctx(),
        );

    await settingsFile().writeAsString(jsonEncode({
      'storage_version': 1,
      'vars': {'log_level': 'info'},
    }));
    await expectLater(export({'from': 'v0_bak', 'include': 'storage'}),
        throwsA(isA<NotFound>()));
    await expectLater(
        export({'from': 'elsewhere'}), throwsA(isA<BadRequest>()));

    // Файл формы 2.23.2 на диске → первое чтение мигрирует и снимает копию.
    final legacy = legacyStorage();
    await settingsFile().writeAsString(jsonEncode(legacy));
    SettingsStorage.resetCacheForTesting();

    final live = body(await export({'include': 'storage'}))['storage'] as Map;
    expect(live['storage_version'], 1);
    expect(live.containsKey('server_lists'), isFalse);

    final v0 = body(await export({'from': 'v0_bak', 'include': 'storage'}));
    expect(v0['app'], 'lxbox');
    expect(v0['kind'], 'backup');
    expect(v0['storage'], legacy,
        reason: 'конверт внутреннего бэкапа с состоянием формы 2.23.2');
  });
}
