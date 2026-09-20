// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/chain_record.dart';
import 'package:lxbox/models/codec/dns_record.dart';
import 'package:lxbox/models/codec/rule_record.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/debug_entry.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/services/app_log.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/storage_migration/legacy_form_v0.dart';
import 'package:lxbox/services/storage_migration/migrate_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$root/docs';
  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

const _uriTokyo = 'vless://11111111-1111-1111-1111-111111111111@198.51.100.1:443'
    '?type=ws&security=tls#Tokyo';
const _uriOsaka = 'vless://22222222-2222-2222-2222-222222222222@198.51.100.2:443'
    '?type=ws&security=tls#Osaka';

/// Небольшой документ формы 2.23.2: по записи каждого вида и соседние ключи.
Map<String, dynamic> _legacyDoc() => {
      'vars': {'log_level': 'warn', 'auto_rebuild': 'false'},
      'server_lists': [
        {
          'type': 'subscription',
          'id': 'sub-1',
          'name': 'Provider',
          'enabled': true,
          'tag_prefix': 'PR',
          'url': 'https://example.com/sub/1',
          'update_interval_hours': 6,
          'disabled_hashes': {'NL-1': '2026-07-18T10:00:00.000Z'},
        },
        {
          'type': 'user',
          'id': 'srv-1',
          'name': '',
          'enabled': true,
          'origin': 'paste',
          'created_at': '2026-01-01T00:00:00.000',
          'raw_body': _uriTokyo,
          'detour_policy': {'override_detour': 'vpn-2'},
        },
        {
          'type': 'folder',
          'id': 'fold-1',
          'name': 'Personal',
          'enabled': true,
          'tag_prefix': 'F',
          'created_at': '2026-02-02T00:00:00.000',
          'members': [
            {'raw': _uriOsaka, 'enabled': true, 'detour': 'Tokyo'},
            {'raw': 'foo://garbage', 'enabled': false},
          ],
        },
      ],
      'route_final': 'vpn-1',
      'chains': [
        {'tag': 'late', 'hops': ['early', 'vpn-1'], 'order': 9},
        {'tag': 'no-order', 'hops': ['a', 'b']},
        {'tag': 'early', 'hops': ['Tokyo', 'vpn-1'], 'order': 3, 'label': 'E'},
      ],
      'custom_rules': [
        {
          'id': 'r-ads',
          'name': 'Ads',
          'enabled': true,
          'kind': 'inline',
          'num': 960,
          'domainSuffixes': ['.ads.example'],
          'outbound': 'reject',
        },
        {
          'id': 'r-srs',
          'name': 'Geo',
          'enabled': true,
          'kind': 'srs',
          'num': 1010,
          'srsUrl': 'https://example.com/a.srs',
          'srsUrls': ['https://example.com/a.srs', 'https://example.com/b.srs'],
          'updateIntervalHours': 720,
          'outbound': 'vpn-1',
        },
        {
          'id': 'r-preset',
          'name': 'Russia direct',
          'enabled': false,
          'kind': 'preset',
          'num': 1120,
          'presetId': 'ru-direct',
          'varsValues': {'outbound': 'direct-out'},
        },
      ],
      'dns_options': {
        'servers': [
          {
            'enabled': true,
            'kind': 'inline',
            'tag': 'my-doh',
            'body': {'type': 'https', 'server': 'dns.example'},
            'description': 'Mine',
          },
          {'enabled': false, 'kind': 'preset', 'tag': 'yandex_udp'},
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
          {'kind': 'preset', 'presetId': 'ru-direct', 'enabled': true},
          {'kind': 'srs', 'name': 'geo', 'id': 'ds_1', 'server': 'my-doh'},
          {'kind': 'template', 'name': 'Default', 'enabled': true},
        ],
        'rules_json': '[]',
      },
      'directions': [
        {'tag': 'vpn-1', 'label': 'Main', 'enabled': true},
      ],
      'directions_migrated': true,
      'excluded_nodes': ['x'],
      'preset_ids_remapped': true,
      'proxy_sources': [],
      'app_rules': [],
      'enabled_rules': [],
      'rule_outbounds': {},
      'node_overrides': {},
      'show_detour_servers': true,
      'tun_apps': {'mode': 'off', 'packages': []},
    };

List<Map<String, dynamic>> _records(Object? list) =>
    (list as List).cast<Map<String, dynamic>>();

void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

  group('migrateStorageDoc — форма 2.23.2 → записи 1.0 (§3.1 шаг 3)', () {
    test('ключи верхнего уровня: sources/rules/dns на месте легаси, версия '
        'первой, прочие ключи как были', () {
      final input = _legacyDoc();
      final snapshot = jsonEncode(input);
      final r = migrateStorageDoc(input,
          presetIdByDnsServerTag: const {'yandex_udp': 'ru-direct'});

      expect(r.migrated, isTrue);
      expect(r.foundVersion, isNull);
      expect(jsonEncode(input), snapshot, reason: 'вход не мутируется');
      expect(r.doc.keys.toList(), [
        'storage_version',
        'vars',
        'sources',
        'route_final',
        'rules',
        'dns',
        'directions',
        'directions_migrated',
        'tun_apps',
      ]);
      expect(r.doc['storage_version'], 1);
      expect(r.doc['route_final'], 'vpn-1');
      expect(r.doc['directions'], input['directions']);
      expect(r.doc['tun_apps'], input['tun_apps']);
    });

    test('источники: запись читается в ту же модель, что читала 2.23.2', () {
      final input = _legacyDoc();
      final r = migrateStorageDoc(input);
      final sources = _records(r.doc['sources']);
      final legacy = _records(input['server_lists']);

      expect(sources.map((s) => s['kind']),
          ['subscription', 'server', 'folder', 'chain', 'chain', 'chain']);
      for (var i = 0; i < legacy.length; i++) {
        expect(sourceFromRecord(sources[i]).value,
            readLegacyServerList(legacy[i]),
            reason: legacy[i]['id'] as String);
      }
      final server = sources[1];
      expect(server['origin'], {'kind': 'uri', 'raw': _uriTokyo});
      expect(server['detour'], {'tag': 'vpn-2'});
      expect(sources[2]['tag_policy'], {'prefix': 'F '});
    });

    test('цепочки хвостом sources[] по старому order, без order — в конце', () {
      final r = migrateStorageDoc(_legacyDoc());
      final chains = [
        for (final s in _records(r.doc['sources']))
          if (s['kind'] == 'chain') chainFromRecord(s).value!,
      ];
      expect(chains.map((c) => c.tag), ['early', 'late', 'no-order']);
      expect(chains.first.label, 'E');
      expect(chains[1].hops, const [NodeLink(tag: 'early'), NodeLink(tag: 'vpn-1')]);
      expect(_records(r.doc['sources']).every((s) => !s.containsKey('order')),
          isTrue);
    });

    test('правила: запись читается в ту же модель, TTL и два refs у srs', () {
      final input = _legacyDoc();
      final r = migrateStorageDoc(input);
      final rules = _records(r.doc['rules']);
      final legacy = _records(input['custom_rules']);
      expect(rules, hasLength(3));
      for (var i = 0; i < legacy.length; i++) {
        expect(ruleFromRecord(rules[i], unknownAsVerbatim: true).value,
            readLegacyCustomRule(legacy[i]),
            reason: legacy[i]['name'] as String);
      }
      expect(rules[1]['refs'],
          ['https://example.com/a.srs', 'https://example.com/b.srs']);
      expect(rules[1]['update_interval_hours'], 720);
      expect(rules[2]['ref'], 'ru-direct');
      expect(rules[2]['vars'], {'outbound': 'direct-out'});
    });

    test('DNS: словарь записей, ref preset-сервера по карте шаблона, '
        'rules_json уходит молча', () {
      final r = migrateStorageDoc(_legacyDoc(),
          presetIdByDnsServerTag: const {'yandex_udp': 'ru-direct'});
      final dns = r.doc['dns'] as Map<String, dynamic>;
      expect(dns.keys.toList(), ['servers', 'rules']);
      expect(dns['servers'], [
        {
          'kind': 'user',
          'tag': 'my-doh',
          'enabled': true,
          'body': {'type': 'https', 'server': 'dns.example'},
          'description': 'Mine',
        },
        {'kind': 'preset', 'ref': 'ru-direct:yandex_udp', 'enabled': false},
        {
          'kind': 'template',
          'tag': 'google_doh',
          'enabled': true,
          'vars': {'outbound': 'vpn-1'},
        },
      ]);
      expect(dns['rules'], [
        {
          'kind': 'user',
          'name': 'corp',
          'enabled': true,
          'body': {
            'domain_suffix': ['.corp'],
            'server': 'my-doh',
          },
        },
        {'kind': 'preset', 'ref': 'ru-direct', 'enabled': true},
        {'kind': 'srs', 'name': 'geo', 'id': 'ds_1', 'server': 'my-doh'},
        {'kind': 'template', 'name': 'Default', 'enabled': true},
      ]);
      expect(r.warnings.where((w) => w.contains('rules_json')), isEmpty);
    });

    test('preset-сервер без известного пресета: ref = тег, отметка в отчёте',
        () {
      final r = migrateStorageDoc(_legacyDoc());
      final servers = _records((r.doc['dns'] as Map)['servers']);
      expect(servers[1]['ref'], 'yandex_udp');
      final back = dnsServerFromRecord(servers[1]).value! as DnsServerPreset;
      expect(back.tag, 'yandex_udp');
      expect(back.presetId, '');
      expect(r.info.join('\n'), contains('yandex_udp'));
    });
  });

  group('мёртвые ключи и отчёт', () {
    test('ключи без читателей удаляются и перечисляются в info', () {
      final r = migrateStorageDoc(_legacyDoc());
      const dead = [
        'excluded_nodes',
        'preset_ids_remapped',
        'proxy_sources',
        'app_rules',
        'enabled_rules',
        'rule_outbounds',
        'node_overrides',
        'show_detour_servers',
      ];
      for (final k in dead) {
        expect(r.doc.containsKey(k), isFalse, reason: k);
      }
      expect(r.doc['vars'], {'log_level': 'warn'});
      final dropped = r.info.singleWhere((l) => l.startsWith('dropped keys'));
      for (final k in [...dead, 'vars.auto_rebuild']) {
        expect(dropped, contains(k));
      }
    });

    test('info: счётчики сущностей; summary — одна строка', () {
      final r = migrateStorageDoc(_legacyDoc());
      expect(r.info, contains('sources: 1 subscriptions, 1 servers, 1 folders, 3 chains'));
      expect(r.info, contains('rules: 3 rules → 3 records'));
      expect(r.info, contains('dns: 3 servers, 4 rules'));
      expect(r.summary, r.info.join('; '));
      // Документ без Направлений: ссылки на vpn-2 и позиции «a», «b» ни во
      // что не разрешаются — миграция ссылок оставляет их корнем и называет
      // (сборка разберёт fail-closed). vpn-1 — цель route_final шаблона.
      expect(r.warnings, [
        'server "Tokyo": detour "vpn-2" matches no node, kept as a root link',
        'chain "no-order": position 1 "a" matches no node, kept as a root link',
        'chain "no-order": position 2 "b" matches no node, kept as a root link',
      ]);
      expect(r.toReportJson(),
          {'migrated': true, 'info': r.info, 'warnings': r.warnings});
    });

    test('warnings называют потерянное по именам записей', () {
      final doc = _legacyDoc();
      doc['server_lists'] = <Object?>[
        ...doc['server_lists'] as List,
        {'type': 'alien', 'id': 'alien-1', 'name': 'Future'},
        'not an object',
        {
          'type': 'user',
          'id': 'srv-multi',
          'name': '',
          'raw_body': '$_uriTokyo\n$_uriOsaka',
        },
      ];
      doc['chains'] = <Object?>[
        ...doc['chains'] as List,
        {'hops': ['a', 'b']},
      ];
      doc['custom_rules'] = <Object?>[
        ...doc['custom_rules'] as List,
        {
          'id': 'r-ports',
          'name': 'Ports with text',
          'kind': 'inline',
          'ports': ['53', 'abc'],
          'outbound': 'direct-out',
        },
        {'id': 'r-bad', 'name': 'Json broken', 'kind': 'json', 'json': '{no'},
      ];
      final dnsOptions =
          Map<String, dynamic>.of(doc['dns_options'] as Map<String, dynamic>);
      dnsOptions['servers'] = <Object?>[
        ...dnsOptions['servers'] as List,
        {'tag': 'pre-043', 'type': 'udp', 'server': '1.1.1.1'},
      ];
      dnsOptions['rules'] = <Object?>[
        ...dnsOptions['rules'] as List,
        {'kind': 'user', 'name': 'old-user', 'rule': {}},
      ];
      dnsOptions['strange'] = 1;
      doc['dns_options'] = dnsOptions;

      final r = migrateStorageDoc(doc);
      final w = r.warnings.join('\n');
      expect(w, contains('alien-1'));
      expect(w, contains('server_lists[4]: not an object'));
      expect(w, contains('chain without tag'));
      expect(w, contains('"Ports with text": non-numeric ports dropped: abc'));
      expect(w, contains('"Json broken"'));
      expect(w, contains('pre-043'));
      expect(w, contains('old-user'));
      expect(w, contains('dns_options.strange'));
      expect(r.info.join('\n'), contains('srv-multi'),
          reason: 'сервер из нескольких узлов назван в отчёте');
      final multi = _records(r.doc['sources'])
          .singleWhere((s) => s['id'] == 'srv-multi');
      expect(multi['tag'], 'Tokyo');
    });
  });

  group('json-правило (§2.3 п. 3, В2)', () {
    Map<String, dynamic> withRule(String json) => {
          'custom_rules': [
            {
              'id': 'r-json',
              'name': 'Raw',
              'enabled': false,
              'kind': 'json',
              'num': 1021,
              'json': json,
            },
          ],
        };

    test('массив делится по объекту: имя #N, общий num и enabled, первый '
        'держит id; не-объекты отброшены с отметкой', () {
      final r = migrateStorageDoc(withRule(
          '[{"action":"sniff"}, 42, {"domain_suffix":[".x"],"outbound":"vpn-1"}]'));
      final rules = _records(r.doc['rules']);
      expect(rules.map((x) => x['name']), ['Raw', 'Raw #2']);
      expect(rules.map((x) => x['num']), [1021, 1021]);
      expect(rules.map((x) => x['enabled']), [false, false]);
      expect(rules.map((x) => x['verbatim']), [true, true]);
      expect(rules[0]['id'], 'r-json');
      expect(rules[1]['id'], isA<String>());
      expect(rules[1]['id'], isNot('r-json'));
      expect(rules[0]['body'], {'action': 'sniff'});
      expect(rules[1]['body'], {
        'domain_suffix': ['.x'],
        'outbound': 'vpn-1',
      });
      expect(r.info, contains('json rules split: "Raw" → 2'));
      expect(r.warnings.single, contains('1 non-object element'));
    });

    test('объект — одна verbatim-запись, ключи `//` сохраняются в теле', () {
      final r = migrateStorageDoc(
          withRule('{"//":"why","domain_keyword":["k"],"outbound":"vpn-1"}'));
      final rule = _records(r.doc['rules']).single;
      expect(rule['kind'], 'inline');
      expect(rule['verbatim'], isTrue);
      expect(rule['body'], {
        '//': 'why',
        'domain_keyword': ['k'],
        'outbound': 'vpn-1',
      });
      expect(r.warnings, isEmpty);
      expect(ruleFromRecord(rule, unknownAsVerbatim: true).value,
          readLegacyCustomRule(
              (withRule('{"//":"why","domain_keyword":["k"],"outbound":"vpn-1"}')[
                      'custom_rules'] as List)
                  .single as Map<String, dynamic>));
    });

    test('нечитаемый текст — verbatim без body и предупреждение', () {
      final r = migrateStorageDoc(withRule('{not json'));
      final rule = _records(r.doc['rules']).single;
      expect(rule['verbatim'], isTrue);
      expect(rule.containsKey('body'), isFalse);
      expect(r.warnings.single, contains('"Raw"'));
      expect(r.warnings.single, contains('.v0.bak'));
    });
  });

  group('Направления: channels (§393 A2)', () {
    test('channels без directions → directions и guard directions_migrated', () {
      final list = [
        {'tag': 'vpn-1', 'label': 'Only', 'enabled': true},
      ];
      final r = migrateStorageDoc({'channels': list});
      expect(r.doc['directions'], list);
      expect(r.doc['directions_migrated'], isTrue,
          reason: 'прерванная установка писала список без маркера');
      expect(r.doc.containsKey('channels'), isFalse);
      expect(r.info.join('\n'), contains('channels → directions'));
    });

    test('channels + channels_migrated переименовываются парой', () {
      final r = migrateStorageDoc({
        'channels': [
          {'tag': 'vpn-1', 'label': 'A', 'enabled': true},
        ],
        'channels_migrated': true,
      });
      expect(r.doc['directions_migrated'], isTrue);
      expect(r.doc.containsKey('channels_migrated'), isFalse);
    });

    test('directions есть — новое имя сильнее: легаси-пара уходит, guard '
        'ставится', () {
      final live = [
        {'tag': 'vpn-1', 'label': 'Live', 'enabled': true},
      ];
      final r = migrateStorageDoc({
        'directions': live,
        'channels': [
          {'tag': 'vpn-1', 'label': 'Stale', 'enabled': true},
        ],
      });
      expect(r.doc['directions'], live);
      expect(r.doc['directions_migrated'], isTrue);
      expect(r.doc.containsKey('channels'), isFalse);
      expect(r.info.join('\n'), contains('dropped keys: channels'));
    });

    test('только channels_migrated: маркер переносится как есть', () {
      final r = migrateStorageDoc({'channels_migrated': true});
      expect(r.doc['directions_migrated'], isTrue);
      expect(r.doc.containsKey('directions'), isFalse);
    });
  });

  group('версия формы', () {
    test('идемпотентна: результат, поданный снова, не меняется и не '
        'копируется', () {
      final first = migrateStorageDoc(_legacyDoc());
      final second = migrateStorageDoc(first.doc);
      expect(second.migrated, isFalse);
      expect(second.foundVersion, 1);
      expect(identical(second.doc, first.doc), isTrue);
      expect(second.info, isEmpty);
      expect(second.warnings, isEmpty);
      expect(storageDocNeedsMigration(first.doc), isFalse);
    });

    test('документ без легаси-ключей получает только версию', () {
      final r = migrateStorageDoc({
        'vars': {'log_level': 'info'},
        'route_final': 'vpn-1',
      });
      expect(r.migrated, isTrue);
      expect(r.doc, {
        'storage_version': 1,
        'vars': {'log_level': 'info'},
        'route_final': 'vpn-1',
      });
      expect(r.info, isEmpty);
    });

    test('версия и легаси-ключи вместе: легаси отброшены с warning, записи '
        'остаются, версия та же', () {
      final current = migrateStorageDoc(_legacyDoc()).doc;
      final doc = {
        ...current,
        // 2.23.2 поверх данных 2.23.3 без удаления (§3.5).
        'server_lists': [
          {'type': 'user', 'id': 'stale', 'name': '', 'raw_body': _uriOsaka},
        ],
        'custom_rules': [],
      };
      final r = migrateStorageDoc(doc);
      expect(r.migrated, isTrue);
      expect(r.foundVersion, 1);
      expect(r.doc['storage_version'], 1);
      expect(r.doc.containsKey('server_lists'), isFalse);
      expect(r.doc.containsKey('custom_rules'), isFalse);
      expect(r.doc['sources'], current['sources']);
      expect(r.doc['rules'], current['rules']);
      expect(r.doc['dns'], current['dns']);
      expect(r.warnings.single,
          allOf(contains('server_lists'), contains('custom_rules')));
    });

    test('версия выше известной без легаси-ключей: документ как есть', () {
      final doc = {
        'storage_version': 2,
        'sources': [],
        'future_key': {'x': 1},
      };
      final r = migrateStorageDoc(doc);
      expect(r.migrated, isFalse);
      expect(r.foundVersion, 2);
      expect(identical(r.doc, doc), isTrue);
    });

    test('storage_version не числом — форма 2.23.2 с предупреждением', () {
      final r = migrateStorageDoc({
        'storage_version': 'one',
        'custom_rules': [],
      });
      expect(r.doc['storage_version'], 1);
      expect(r.doc['rules'], isEmpty);
      expect(r.warnings.single, contains('"one"'));
    });

    test('sources без версии рядом с server_lists: побеждают легаси-ключи '
        'того же документа', () {
      final r = migrateStorageDoc({
        'sources': [
          {'kind': 'server', 'id': 'orphan'},
        ],
        'server_lists': [
          {'type': 'user', 'id': 'real', 'name': '', 'raw_body': _uriTokyo},
        ],
      });
      expect(_records(r.doc['sources']).single['id'], 'real');
      expect(r.warnings.single, contains('"sources" without storage_version'));
    });
  });

  // ─── чтение файла: §3.1 шаги 4–6, §3.2 ──────────────────────────────────

  group('_load: копия .v0.bak, запись, повтор', () {
    late Directory tmp;

    File main() => File('${tmp.path}/docs/lxbox_settings.json');
    File bak() => File('${tmp.path}/docs/lxbox_settings.json.bak');
    File v0() => File('${tmp.path}/docs/lxbox_settings.json.v0.bak');
    Map<String, dynamic> readMain() =>
        jsonDecode(main().readAsStringSync()) as Map<String, dynamic>;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tmp = await Directory.systemTemp.createTemp('migrate_storage_load_');
      for (final sub in const ['docs', 'support', 'tmp']) {
        await Directory('${tmp.path}/$sub').create();
      }
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
      SettingsStorage.resetCacheForTesting();
      AppLog.I.resetForTesting();
    });

    tearDown(() async {
      SettingsStorage.resetCacheForTesting();
      try {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      } on FileSystemException {
        // AppLog пишет persistent-лог в docs async — race с delete.
      }
    });

    test('первое чтение мигрирует: файл формы 1.0, копия исходных байтов, '
        '.bak = старый файл, configDirty не поднят', () async {
      final original = const JsonEncoder.withIndent('    ').convert(_legacyDoc());
      await main().writeAsString(original);

      final lists = await SettingsStorage.getServerLists();
      expect(lists.map((l) => l.id), ['sub-1', 'srv-1', 'fold-1']);
      expect((await SettingsStorage.getChains()).map((c) => c.tag),
          ['early', 'late', 'no-order']);

      final onDisk = readMain();
      expect(onDisk['storage_version'], 1);
      for (final k in kLegacyStorageKeys) {
        expect(onDisk.containsKey(k), isFalse, reason: k);
      }
      expect(v0().readAsStringSync(), original,
          reason: 'копия — исходные байты, не переформатированные');
      expect(bak().readAsStringSync(), original,
          reason: '_atomicSave кладёт прежний main в .bak');
      expect(SettingsStorage.configDirty, isFalse);

      final logs = AppLog.I.entries.map((e) => e.message).join('\n');
      expect(logs, contains('storage migrated to storage_version 1'));
    });

    test('повторный старт: файл текущей формы не переписывается, копия та же',
        () async {
      await main().writeAsString(jsonEncode(_legacyDoc()));
      await SettingsStorage.getServerLists();
      final migrated = main().readAsStringSync();
      final migratedStat = main().statSync().modified;
      final copy = v0().readAsStringSync();

      SettingsStorage.resetCacheForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await SettingsStorage.getServerLists()), hasLength(3));
      expect(main().readAsStringSync(), migrated);
      expect(main().statSync().modified, migratedStat);
      expect(v0().readAsStringSync(), copy);
    });

    test('.v0.bak пишется один раз: следующая миграция её не перетирает',
        () async {
      final first = jsonEncode(_legacyDoc());
      await main().writeAsString(first);
      await SettingsStorage.getServerLists();

      // Снова файл формы 2.23.2 (откат на 2.23.2 поверх данных и возврат).
      SettingsStorage.resetCacheForTesting();
      await main().writeAsString(jsonEncode({
        'custom_rules': [
          {'id': 'x', 'name': 'Later', 'kind': 'inline', 'outbound': 'vpn-1'},
        ],
      }));
      final rules = await SettingsStorage.getCustomRules();
      expect(rules.single.name, 'Later');
      expect(readMain()['storage_version'], 1);
      expect(v0().readAsStringSync(), first,
          reason: 'существующая копия — самый первый исходник');
    });

    test('сбой между шагами 4 и 5: старый файл + копия → миграция заново, '
        'копия не перезаписывается', () async {
      final legacy = jsonEncode(_legacyDoc());
      await main().writeAsString(legacy);
      // Копию сняли, до записи нового файла процесс убили.
      const earlierCopy = '{"server_lists": []}';
      await v0().writeAsString(earlierCopy);

      final lists = await SettingsStorage.getServerLists();
      expect(lists, hasLength(3));
      expect(readMain()['storage_version'], 1);
      expect(v0().readAsStringSync(), earlierCopy);
    });

    test('битый main, .bak формы 2.23.2: восстановление мигрирует и пишет',
        () async {
      await main().writeAsString('{ torn write');
      await bak().writeAsString(jsonEncode(_legacyDoc()));

      expect((await SettingsStorage.getCustomRules()).map((r) => r.name),
          ['Ads', 'Geo', 'Russia direct']);
      expect(readMain()['storage_version'], 1);
      expect(v0().existsSync(), isTrue);
    });

    test('версия выше известной: читается как текущая, не переписывается, '
        'незнакомые ключи переживают запись, строка error', () async {
      final doc = {
        'storage_version': 2,
        'vars': {'log_level': 'info'},
        'future_key': {'x': 1},
      };
      final text = jsonEncode(doc);
      await main().writeAsString(text);

      expect(await SettingsStorage.getVar('log_level', ''), 'info');
      expect(main().readAsStringSync(), text);
      expect(v0().existsSync(), isFalse);
      final errors = AppLog.I.entries
          .where((e) => e.level == DebugLevel.error)
          .map((e) => e.message);
      expect(errors.join('\n'), contains('storage_version 2 is newer'));

      await SettingsStorage.setVar('log_level', 'warn');
      final written = readMain();
      expect(written['storage_version'], 2);
      expect(written['future_key'], {'x': 1});
    });

    test('новая установка: первая запись несёт storage_version', () async {
      expect(main().existsSync(), isFalse);
      await SettingsStorage.setVar('log_level', 'warn');
      expect(readMain()['storage_version'], 1);
      expect(v0().existsSync(), isFalse);
    });

    test('параллельные первые чтения ждут одну миграцию', () async {
      await main().writeAsString(jsonEncode(_legacyDoc()));
      final results = await Future.wait([
        SettingsStorage.getServerLists(),
        SettingsStorage.getServerLists(),
        SettingsStorage.getServerLists(),
      ]);
      for (final r in results) {
        expect(r.map((l) => l.id), ['sub-1', 'srv-1', 'fold-1']);
      }
      final migrations = AppLog.I.entries
          .where((e) => e.message.contains('storage migrated'))
          .length;
      expect(migrations, 1);
      final leftovers = Directory('${tmp.path}/docs')
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .where((n) => n.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    });
  });
}
