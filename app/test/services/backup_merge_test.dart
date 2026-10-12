import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/backup_merge.dart';
import 'package:lxbox/services/backup_service.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §633 — Merge при импорте бэкапа: добавляется то, чего у получателя нет; то,
/// что есть, остаётся его.
void main() {
  Map<String, dynamic> rule(String id, String name, {int? num, bool? on}) => {
    'kind': 'inline',
    'id': id,
    'name': name,
    'enabled': on ?? true,
    'num': ?num,
    'body': {
      'domain_suffix': ['.$name.example'],
      'outbound': 'vpn-1',
    },
  };

  Map<String, dynamic> preset(
    String ref, {
    required bool on,
    Map<String, dynamic>? vars,
    int num = 960,
  }) => {
    'kind': 'preset',
    'id': 'p-$ref-${on ? 1 : 0}',
    'name': ref,
    'enabled': on,
    'num': num,
    'ref': ref,
    'vars': ?vars,
  };

  group('mergeStorageDoc — правила', () {
    test('новые — в конец пользовательских, совпавшие по id и по содержимому '
        'пропущены', () {
      final mine = <String, dynamic>{
        'rules': [rule('a', 'alpha', num: 1000), rule('b', 'beta', num: 1004)],
      };
      final file = <String, dynamic>{
        'rules': [
          rule('a', 'alpha-changed', num: 1000), // тот же id
          {...rule('x', 'beta', num: 1001), 'enabled': false}, // то же тело
          rule('c', 'gamma', num: 1000),
          rule('d', 'delta', num: 955),
        ],
      };
      final stats = mergeStorageDoc(mine, file);
      final rules = (mine['rules'] as List).cast<Map>();
      expect(rules.map((r) => r['id']), ['a', 'b', 'c', 'd']);
      expect(rules.first['name'], 'alpha', reason: 'запись получателя');
      expect(rules[2]['num'], 1005, reason: 'за последним своим правилом');
      expect(rules[3]['num'], 1006);
      expect(stats.rules.added, 2);
      expect(stats.rules.kept, 2);
    });

    test('пресет: включён у кого-либо — включён; параметры у того, у кого '
        'включён', () {
      final mine = <String, dynamic>{
        'rules': [
          preset('ads', on: false, vars: {'outbound': 'direct-out'}),
          preset('ru', on: true, vars: {'outbound': 'vpn-1'}),
        ],
      };
      final file = <String, dynamic>{
        'rules': [
          preset('ads', on: true, vars: {'outbound': 'block'}),
          preset('ru', on: false, vars: {'outbound': 'vpn-2'}),
          preset('games', on: true, num: 970),
        ],
      };
      final stats = mergeStorageDoc(mine, file);
      final rules = (mine['rules'] as List).cast<Map>();
      expect(rules.map((r) => r['ref']), ['ads', 'ru', 'games']);
      expect(rules[0]['enabled'], isTrue);
      expect(rules[0]['vars'], {'outbound': 'block'});
      expect(rules[0]['id'], 'p-ads-0', reason: 'запись получателя');
      expect(rules[1]['enabled'], isTrue);
      expect(rules[1]['vars'], {'outbound': 'vpn-1'});
      expect(rules[2]['num'], 970, reason: 'новый пресет — с номером шаблона');
      expect(stats.rules.added, 1);
      expect(stats.rules.kept, 2);
    });
  });

  test('Направления: по тегу, vpn-1 получателя, тег цепочки не берётся', () {
    final mine = <String, dynamic>{
      'directions': [
        {'tag': 'vpn-1', 'label': 'Mine'},
        {'tag': 'vpn-2', 'label': 'Two'},
      ],
      'sources': [
        {'kind': 'chain', 'tag': 'work', 'hops': []},
      ],
    };
    final file = <String, dynamic>{
      'directions': [
        {'tag': 'vpn-1', 'label': 'Theirs'},
        {'tag': 'vpn-3', 'label': 'Three'},
        {'tag': 'work', 'label': 'Clash'},
      ],
    };
    final stats = mergeStorageDoc(mine, file);
    final dirs = (mine['directions'] as List).cast<Map>();
    expect(dirs.map((d) => d['tag']), ['vpn-1', 'vpn-2', 'vpn-3']);
    expect(dirs.first['label'], 'Mine');
    expect(stats.directions.added, 1);
    expect(stats.directions.kept, 2);
  });

  test(
    'DNS: серверы по тегу / ref, правила по ref, name шаблона, отпечатку',
    () {
      final mine = <String, dynamic>{
        'dns': {
          'servers': [
            {
              'kind': 'user',
              'tag': 'my-doh',
              'body': {'type': 'https'},
            },
            {'kind': 'preset', 'ref': 'ru-direct:yandex_udp', 'enabled': true},
          ],
          'rules': [
            {'kind': 'preset', 'ref': 'ru-direct', 'enabled': true},
            {
              'kind': 'user',
              'name': 'corp',
              'enabled': true,
              'body': {
                'domain_suffix': ['.corp'],
                'server': 'my-doh',
              },
            },
          ],
        },
      };
      final file = <String, dynamic>{
        'dns': {
          'servers': [
            {
              'kind': 'user',
              'tag': 'my-doh',
              'body': {'type': 'tls'},
            },
            {'kind': 'preset', 'ref': 'ru-direct:yandex_udp', 'enabled': false},
            {'kind': 'template', 'tag': 'google_doh', 'enabled': true},
          ],
          'rules': [
            {'kind': 'preset', 'ref': 'ru-direct', 'enabled': true},
            {
              'kind': 'user',
              'name': 'corp',
              'enabled': false,
              'body': {
                'domain_suffix': ['.corp'],
                'server': 'my-doh',
              },
            },
            {'kind': 'template', 'name': 'block-ads', 'enabled': true},
          ],
        },
      };
      final stats = mergeStorageDoc(mine, file);
      final dns = mine['dns'] as Map;
      final servers = (dns['servers'] as List).cast<Map>();
      expect(servers.map((s) => s['tag'] ?? s['ref']), [
        'my-doh',
        'ru-direct:yandex_udp',
        'google_doh',
      ]);
      expect(servers.first['body'], {'type': 'https'});
      expect(servers[1]['enabled'], isTrue);
      final rules = (dns['rules'] as List).cast<Map>();
      expect(rules.map((r) => r['ref'] ?? r['name']), [
        'ru-direct',
        'corp',
        'block-ads',
      ]);
      expect(rules[1]['enabled'], isTrue);
      expect((stats.dnsServers.added, stats.dnsServers.kept), (1, 2));
      expect((stats.dnsRules.added, stats.dnsRules.kept), (1, 2));
    },
  );

  group('Tunnel apps', () {
    test('списки объединяются, режим получателя, если он не off', () {
      final mine = <String, dynamic>{
        'tun_apps': {
          'mode': 'allow',
          'packages': ['b.app', 'a.app'],
        },
      };
      final stats = mergeStorageDoc(mine, {
        'tun_apps': {
          'mode': 'deny',
          'packages': ['a.app', 'c.app'],
        },
      });
      expect(mine['tun_apps'], {
        'mode': 'allow',
        'packages': ['a.app', 'b.app', 'c.app'],
      });
      expect((stats.tunApps.added, stats.tunApps.kept), (1, 1));
    });

    test('режим off получателя — режим из файла', () {
      final mine = <String, dynamic>{
        'tun_apps': {'mode': 'off', 'packages': <String>[]},
      };
      mergeStorageDoc(mine, {
        'tun_apps': {
          'mode': 'deny',
          'packages': ['x.app'],
        },
      });
      expect(mine['tun_apps'], {
        'mode': 'deny',
        'packages': ['x.app'],
      });
    });
  });

  test('скаляры и vars: значение получателя, отсутствующие — из файла', () {
    final mine = <String, dynamic>{
      'storage_version': 1,
      'route_final': 'vpn-1',
      'vars': {'log_level': 'info'},
    };
    final stats = mergeStorageDoc(mine, {
      'storage_version': 1,
      'route_final': 'vpn-2',
      'vpn_mode': {'mode': 'proxy'},
      'vars': {'log_level': 'debug', 'debug_port': '9269'},
    });
    expect(mine['route_final'], 'vpn-1');
    expect(mine['vpn_mode'], {'mode': 'proxy'});
    expect(mine['vars'], {'log_level': 'info', 'debug_port': '9269'});
    expect(stats.addedKeys, unorderedEquals(['vpn_mode', 'vars.debug_port']));
    expect(stats.keptKeys, unorderedEquals(['route_final', 'vars.log_level']));

    final byCat = BackupService.mergeCountsByCategory(stats);
    expect(byCat[BackupCategory.routing]!.added, 1);
    expect(byCat[BackupCategory.routing]!.kept, 1);
    expect(byCat[BackupCategory.appSettings]!.kept, 1);
    expect(byCat[BackupCategory.debugConfig]!.added, 1);
  });

  test('источники (вход Debug API): по id, цепочки по тегу', () {
    final mine = <String, dynamic>{
      'sources': [
        {'kind': 'subscription', 'id': 's1', 'url': 'https://a'},
        {'kind': 'chain', 'tag': 'work', 'hops': []},
      ],
      'directions': [
        {'tag': 'vpn-1'},
      ],
    };
    final stats = mergeStorageDoc(mine, {
      'sources': [
        {'kind': 'subscription', 'id': 's1', 'url': 'https://b'},
        {'kind': 'subscription', 'id': 's2', 'url': 'https://c'},
        {
          'kind': 'chain',
          'tag': 'work',
          'hops': ['x'],
        },
        {'kind': 'chain', 'tag': 'vpn-1', 'hops': []},
        {'kind': 'chain', 'tag': 'home', 'hops': []},
      ],
    });
    final src = (mine['sources'] as List).cast<Map>();
    expect(src.map((r) => r['id'] ?? r['tag']), ['s1', 'work', 's2', 'home']);
    expect(src.first['url'], 'https://a');
    expect((stats.sources.added, stats.sources.kept), (2, 3));
  });

  group('BackupService.applyImport(merge: true)', () {
    late Directory tmp;
    const channel = MethodChannel('plugins.flutter.io/path_provider');

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tmp = await Directory.systemTemp.createTemp('lxbox_merge_test_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getApplicationDocumentsDirectory' ||
                call.method == 'getApplicationDocumentsPath') {
              return tmp.path;
            }
            return null;
          });
      SettingsStorage.resetCacheForTesting();
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('Routing: свои правила и Направления на месте, новые дописаны; '
        'превью совпадает с итогом', () async {
      await SettingsStorage.replaceRaw({
        'storage_version': 1,
        'vars': {'log_level': 'info'},
        'rules': [rule('mine', 'mine', num: 1000)],
        'route_final': 'vpn-1',
        'directions': [
          {'tag': 'vpn-1', 'label': 'Main', 'enabled': true},
        ],
        'directions_migrated': true,
      });
      final svc = const BackupService();
      final contents = await svc.parseImport('''
{"app":"lxbox","kind":"backup","storage":{
  "storage_version":1,
  "vars":{"log_level":"debug","auto_update_subs":"false"},
  "rules":[
    {"kind":"inline","id":"mine","name":"other","enabled":true,"num":1000,
     "body":{"domain":["x.example"],"outbound":"vpn-1"}},
    {"kind":"inline","id":"theirs","name":"theirs","enabled":true,"num":1000,
     "body":{"domain":["y.example"],"outbound":"vpn-2"}}
  ],
  "route_final":"vpn-2",
  "directions":[
    {"tag":"vpn-1","label":"Theirs","enabled":true},
    {"tag":"vpn-2","label":"Two","enabled":true}
  ],
  "directions_migrated":true
}}''');
      final preview = await svc.previewMerge(contents);
      final result = await svc.applyImport(
        contents,
        merge: true,
        include: {BackupCategory.routing, BackupCategory.appSettings},
      );
      expect(result.errors, isEmpty);
      expect(result.merged, isTrue);

      final rules = await SettingsStorage.getCustomRules();
      expect(rules.map((r) => r.id), ['mine', 'theirs']);
      expect(rules.first.name, 'mine');
      final dirs = await SettingsStorage.getDirections();
      expect(dirs.map((d) => d.tag), ['vpn-1', 'vpn-2']);
      expect(dirs.first.label, 'Main');
      final raw = await SettingsStorage.exportRaw();
      expect(raw['route_final'], 'vpn-1');
      expect((raw['vars'] as Map)['log_level'], 'info');
      expect((raw['vars'] as Map)['auto_update_subs'], 'false');

      // Добавлены: правило, Направление (Routing); auto_update_subs (App).
      expect(result.routingApplied, 2);
      expect(result.appSettingsApplied, 1);
      expect(preview[BackupCategory.routing]!.added, result.routingApplied);
      expect(
        preview[BackupCategory.appSettings]!.added,
        result.appSettingsApplied,
      );
      expect(
        preview[BackupCategory.routing]!.kept +
            preview[BackupCategory.appSettings]!.kept,
        result.mergeKept,
      );
    });
  });
}
