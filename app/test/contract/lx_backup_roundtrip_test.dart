import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/chain_record.dart';
import 'package:lxbox/models/codec/rule_record.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_sections.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/dns/dns_backup.dart';
import 'package:lxbox/services/json_clone.dart';
import 'package:lxbox/services/lx_backup.dart';

import 'json_schema_lite.dart';

// §438 — запись LX Backup 1.0 и круг «состояние → экспорт → импорт».
//
// Инвариант П1 (BACKUP_PRINCIPLES): `import(export(x))` в том же приложении
// = `x`, а импорт собственного экспорта в то же состояние ничего не
// добавляет. Состояние собрано из всех видов, которые LxBox умеет выразить в
// 1.0: подписка, одиночные узлы (URI и JSON), две папки-тёзки, член папки с
// секциями и личным detour, нечитаемый член, цепочки с позициями в папку,
// в подписку и в Направление, правила всех видов (включая json), DNS всех
// видов, Направление с бюджетом теста, переносимые vars, route.final.

const _schemaPath = 'contract/schema/backup.schema.json';

/// Состояние стороны в памяти — то, что импорт пишет в storage.
class _State {
  _State({
    this.lists = const [],
    this.chains = const [],
    this.rules = const [],
    this.dnsServers = const [],
    this.dnsRules = const [],
  });

  List<ServerList> lists;
  List<SourceChain> chains;
  List<CustomRule> rules;
  List<Map<String, dynamic>> dnsServers;
  List<Map<String, dynamic>> dnsRules;
  String dnsFinal = '';
  String dnsStrategy = '';
  String dnsResolver = '';
  List<Direction> directions = const [];
  Map<String, LxDirectionPing> directionPing = const {};
  Map<String, String> vars = const {};
  String? routeFinal;
}

const _presetIdByServerTag = {'yandex_udp': 'ru-direct'};

Future<LxBackupExport> _export(_State s) => buildLxBackup(
      lists: s.lists,
      rules: s.rules,
      vars: s.vars,
      directions: s.directions,
      directionPing: s.directionPing,
      chains: s.chains,
      routeFinal: s.routeFinal,
      dns: dnsToBackup(
        servers: s.dnsServers,
        rules: s.dnsRules,
        dnsFinal: s.dnsFinal,
        strategy: s.dnsStrategy,
        defaultDomainResolver: s.dnsResolver,
        presetIdByServerTag: _presetIdByServerTag,
      ),
    );

/// Импорт теми же чистыми функциями, что экран бэкапа.
LxBackupFile _import(_State s, String raw) {
  final file = parseLxBackup(
    raw,
    knownOutbounds: {for (final d in s.directions) d.tag},
    knownChains: {for (final c in s.chains) c.tag},
  );
  final subs = mergeBackupSubscriptions(s.lists, file.subscriptions);
  final servers = mergeBackupServers(
    subs.lists,
    file.servers,
    folders: file.folders,
    sourceIds: subs.ids,
    addedSources: subs.added,
  );
  s.lists = servers.lists;
  s.chains = [
    ...s.chains,
    ...resolveBackupChainHops(file, servers.lists, servers.folderIds),
  ];
  s.rules = renumberBackupAxis(file.rules, servers.lists, servers.touched);
  final dns = applyDnsBackup(
    incoming: file.dns!,
    servers: s.dnsServers,
    rules: s.dnsRules,
    dnsFinal: s.dnsFinal,
    strategy: s.dnsStrategy,
    defaultDomainResolver: s.dnsResolver,
    presetIdByServerTag: _presetIdByServerTag,
  );
  s.dnsServers = dns.servers;
  s.dnsRules = dns.rules;
  s.dnsFinal = dns.dnsFinal;
  s.dnsStrategy = dns.strategy;
  s.dnsResolver = dns.defaultDomainResolver;
  s.directions = [...s.directions, ...file.directions];
  s.directionPing = {...s.directionPing, ...file.directionPing};
  s.vars = {...s.vars, ...file.vars};
  s.routeFinal = file.routeFinal ?? s.routeFinal;
  return file;
}

NodeSections _sections(String name) => NodeSections.fromJson({
      'rules': [
        {
          'kind': 'inline',
          'name': name,
          'enabled': true,
          'num': 945,
          'body': {'ip_cidr': ['100.64.0.0/10'], 'outbound': '@self'},
        },
      ],
      'dns': {
        'servers': [
          {
            'kind': 'user',
            'tag': '@{self}-dns',
            'enabled': true,
            'body': {'type': 'udp', 'server': '100.100.100.100', 'detour': '@self'},
          },
        ],
        'rules': [
          {
            'kind': 'user',
            'name': '',
            'enabled': true,
            'body': {'domain_suffix': ['.ts.net'], 'server': '@{self}-dns'},
          },
        ],
      },
    })!;

String _compact(Map<String, dynamic> j) => jsonEncode(j);

_State _source() {
  final created = DateTime.utc(2026, 9, 1);
  return _State(
    lists: [
      SubscriptionServers(
        id: 'sub-1',
        name: 'Provider',
        enabled: true,
        tagPrefix: 'PR',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example-1.com/sub',
        updateIntervalHours: 12,
        identity: const SubscriptionIdentityOverride(
          userAgent: 'lx/1.0',
          sendHwid: true,
          hwid: 'hw-1',
          deviceOs: 'Android',
        ),
        disabledHashes: {'DE-1': DateTime.utc(2026, 9, 2)},
      ),
      UserServer(
        id: 'srv-1',
        name: 'root-jp',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults.copyWith(overrideDetour: 'EU de-1'),
        origin: UserSource.manual,
        rawBody:
            'vless://11111111-1111-1111-1111-111111111111@example-3.com:443?type=tcp&security=tls&sni=example-3.com#root-jp',
        sections: _sections('@{self} network'),
      ),
      UserServer(
        id: 'srv-2',
        name: 'json-node',
        enabled: false,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        rawBody: _compact({
          'type': 'trojan',
          'tag': 'json-node',
          'server': 'example-4.com',
          'server_port': 443,
          'password': 'p',
        }),
      ),
      FolderServers(
        id: 'fold-a',
        name: 'EU',
        enabled: true,
        tagPrefix: 'EU',
        detourPolicy: DetourPolicy.defaults,
        createdAt: created,
        members: [
          FolderMember(
            raw: _compact({
              'type': 'vless',
              'tag': 'de-1',
              'server': 'example-2.com',
              'server_port': 443,
              'uuid': '11111111-1111-1111-1111-111111111111',
            }),
            sections: _sections('@{self} member net'),
          ),
          FolderMember(
            raw: 'trojan://secret@example-5.com:443#nl-1',
            enabled: false,
            detour: 'root-jp',
          ),
          FolderMember(raw: 'not a node at all'),
        ],
      ),
      // Тёзка первой папки: импорт собственного экспорта обязан держать их
      // раздельно (BACKUP.md §9 п. 3).
      FolderServers(
        id: 'fold-b',
        name: 'EU',
        enabled: false,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        createdAt: created,
        members: [FolderMember(raw: 'trojan://secret@example-6.com:443#fr-1')],
      ),
    ],
    chains: const [
      SourceChain(
        tag: 'jp-via-eu',
        hops: ['EU de-1', 'root-jp'],
        idleTimeout: '0s',
        stripEvasion: false,
        strip: {'tls.utls': true},
        rewrite: {
          'vless': {'flow': null},
        },
      ),
      SourceChain(
        tag: 'sub-then-dir',
        enabled: false,
        hops: ['PR node-x', 'vpn-1'],
      ),
    ],
    rules: [
      CustomRulePreset(
        id: 'r-tp',
        name: 'Traffic processing',
        presetId: 'traffic-processing',
        orderNum: 0,
      ),
      CustomRuleInline(
        id: 'r-ads',
        name: 'Ads',
        domainSuffixes: const ['.ads.example-2.com'],
        outbound: kOutboundReject,
        orderNum: 960,
      ),
      CustomRuleInline(
        id: 'r-corp',
        name: 'Corp',
        domainSuffixes: const ['.corp.example-1.com'],
        outbound: 'vpn-1',
        orderNum: 1000,
      ),
      CustomRuleSrs(
        id: 'r-geo',
        name: 'Geo',
        srsUrls: const ['https://example-3.com/a.srs', 'https://example-3.com/b.srs'],
        outbound: 'vpn-1',
        orderNum: 1001,
      ),
      CustomRuleJson(
        id: 'r-sniff',
        name: 'Sniff',
        json: '{"action":"sniff"}',
        orderNum: 1002,
      ),
      CustomRulePreset(
        id: 'r-ru',
        name: 'Russian',
        presetId: 'ru-direct',
        varsValues: const {'outbound': 'direct-out'},
        orderNum: 1120,
      ),
    ],
    dnsServers: [
      {
        'enabled': true,
        'kind': 'inline',
        'tag': 'my-doh',
        'body': {'type': 'https', 'server': 'example-4.com', 'path': '/dns-query'},
      },
      {'enabled': true, 'kind': 'template', 'tag': 'dns-google'},
      {'enabled': false, 'kind': 'preset', 'tag': 'yandex_udp'},
    ],
    dnsRules: [
      {
        'kind': 'inline',
        'name': 'Local',
        'enabled': true,
        'rule': {'domain_suffix': ['.lan'], 'server': 'my-doh'},
      },
      {'kind': 'preset', 'presetId': 'ru-direct', 'enabled': true},
    ],
  )
    ..dnsFinal = 'my-doh'
    ..dnsStrategy = 'prefer_ipv4'
    ..dnsResolver = 'dns-google'
    ..directions = const [Direction(tag: 'vpn-1', label: 'Main', nodeFilter: 'DE')]
    ..directionPing = {'vpn-1': LxDirectionPing(url: 'https://example-1.com/204', timeoutMs: 2500)}
    ..vars = const {'log_level': 'debug', 'tun_mtu': '1400'}
    ..routeFinal = 'vpn-1';
}

/// Снимок состояния для сравнения: JSON storage, без меток времени создания
/// (новая запись получает «сейчас»).
Object? _snapshot(_State s) {
  // `origin` одиночного сервера — write-only диагностика (§219: как узел
  // добавлен); импорт ставит `manual`, в 1.0 дома у поля нет и поведения оно
  // не меняет.
  Object? strip(Object? v) {
    if (v is Map) {
      return {
        for (final e in v.entries)
          if (e.key != 'created_at' && !(e.key == 'origin' && e.value is String))
            '${e.key}': strip(e.value),
      };
    }
    if (v is List) return [for (final e in v) strip(e)];
    return v;
  }

  return strip(jsonDecode(jsonEncode({
    'lists': [for (final l in s.lists) sourceToRecord(l)],
    'chains': [for (final c in s.chains) chainToRecord(c)],
    'rules': [for (final r in s.rules) ruleToRecord(r)],
    'dns_servers': s.dnsServers,
    'dns_rules': s.dnsRules,
    'dns_final': s.dnsFinal,
    'dns_strategy': s.dnsStrategy,
    'dns_resolver': s.dnsResolver,
    'directions': [for (final d in s.directions) d.toJson()],
    'direction_ping': {
      for (final e in s.directionPing.entries) e.key: e.value.toStorage(),
    },
    'vars': s.vars,
    'route_final': s.routeFinal,
  })));
}

void main() {
  group('§438 запись LX Backup 1.0', () {
    test('экспорт — форма 1.0 и валиден по схеме', () async {
      final out = await _export(_source());
      expect(out.warnings, isEmpty,
          reason: 'в состоянии нет настроек без дома в 1.0');
      final doc = jsonDecode(out.json) as Map<String, dynamic>;
      expect(doc['lx_backup'], 2);
      expect(doc.keys, [
        'lx_backup',
        'exported_by',
        'exported_at',
        'sources',
        'directions',
        'rules',
        'dns',
        'vars',
        'route',
      ]);
      final kinds = [for (final s in doc['sources'] as List) (s as Map)['kind']];
      expect(kinds, ['subscription', 'server', 'server', 'folder', 'folder', 'chain', 'chain']);

      final schemaFile = File(_schemaPath);
      if (!schemaFile.existsSync()) {
        markTestSkipped('контракт не синхронизирован');
        return;
      }
      final schema = jsonDecode(schemaFile.readAsStringSync()) as Map<String, dynamic>;
      expect(validateJsonSchema(doc, schema), isEmpty);
    });

    test('ссылки: префикс папки и подписки → folder_id, preset DNS → preset_id:tag', () async {
      final doc = jsonDecode((await _export(_source())).json) as Map<String, dynamic>;
      final sources = (doc['sources'] as List).cast<Map<String, dynamic>>();
      final chain = sources.firstWhere((s) => s['tag'] == 'jp-via-eu');
      expect(chain['hops'], [
        {'folder_id': 'fold-a', 'tag': 'de-1'},
        {'tag': 'root-jp'},
      ]);
      final toSub = sources.firstWhere((s) => s['tag'] == 'sub-then-dir');
      expect(toSub['hops'], [
        {'folder_id': 'sub-1', 'tag': 'node-x'},
        {'tag': 'vpn-1'},
      ]);
      final root = sources.firstWhere((s) => s['tag'] == 'root-jp');
      expect(root['detour'], {'folder_id': 'fold-a', 'tag': 'de-1'});
      final folder = sources.firstWhere((s) => s['id'] == 'fold-a');
      final members = (folder['nodes'] as List).cast<Map<String, dynamic>>();
      expect(members.map((m) => m['kind']), ['server', 'server', 'unsupported']);
      expect(members[1]['detour'], {'tag': 'root-jp'});
      expect((members[2]['origin'] as Map)['raw'], 'not a node at all');

      final rules = (doc['rules'] as List).cast<Map<String, dynamic>>();
      final sniff = rules.firstWhere((r) => r['name'] == 'Sniff');
      expect(sniff['kind'], 'inline', reason: 'вида json в 1.0 нет');
      expect(sniff['body'], {'action': 'sniff'});
      final dnsServers = ((doc['dns'] as Map)['servers'] as List).cast<Map<String, dynamic>>();
      expect(dnsServers.last, {'kind': 'preset', 'ref': 'ru-direct:yandex_udp', 'enabled': false});
      expect((doc['dns'] as Map)['default_domain_resolver'], 'dns-google');
    });

    test('круг: экспорт → импорт в пустое состояние = исходное состояние', () async {
      final source = _source();
      final out = await _export(source);
      final target = _State();
      final file = _import(target, out.json);
      expect(file.warnings, isEmpty, reason: 'свой файл читается без потерь');
      final got = _snapshot(target) as Map;
      final want = _snapshot(source) as Map;
      for (final k in want.keys) {
        expect(got[k], _deepEquals(want[k]), reason: k);
      }
      expect(got.keys.toSet(), want.keys.toSet());
      // Экспорт восстановленного состояния — тот же файл (без метки времени).
      String stable(String raw) =>
          jsonEncode((jsonDecode(raw) as Map)..remove('exported_at'));
      expect(stable((await _export(target)).json), stable(out.json));
    });

    test('импорт собственного экспорта в совпадающее состояние ничего не добавляет', () async {
      final source = _source();
      final out = await _export(source);
      final state = _State();
      _import(state, out.json);
      final before = _snapshot(state);

      final again = _import(state, out.json);
      expect(again.warnings.map((w) => w.code).toSet(),
          {kWarnChainExists, kWarnDirectionExists},
          reason: 'своя цепочка и своё Направление под тем же тегом сильнее — '
              'и названы');
      expect(_snapshot(state), _deepEquals(before),
          reason: 'папки-тёзки, узлы, DNS и правила не задвоились');
      expect(state.lists.whereType<FolderServers>().map((f) => f.members.length), [3, 1]);
    });

    test('настройки без дома в 1.0 названы, а не потеряны молча', () async {
      final state = _source();
      state.lists = [
        (state.lists[0] as SubscriptionServers).copyWith(
          onUpdateAction: SubscriptionOnUpdateAction.reload,
          detourPolicy: DetourPolicy.defaults.copyWith(overrideDetour: 'vpn-1'),
        ),
        (state.lists[3] as FolderServers).copyWith(pingUrl: 'https://example-1.com/204'),
      ];
      state.chains = const [SourceChain(tag: 'c', label: 'Named', hops: ['a', 'b'])];
      state.rules = [CustomRuleJson(name: 'Broken', json: 'not json')];
      state.dnsRules = [
        ...state.dnsRules,
        {'kind': 'srs', 'id': 's1', 'name': 'Geo', 'enabled': true},
      ];
      final out = await _export(state);
      expect(
        out.warnings.map((w) => '${w.code} ${w.detail}').toList(),
        [
          '$kWarnLocalOnlyDropped Provider: on_update_action, detour_policy',
          '$kWarnLocalOnlyDropped EU: ping_url',
          '$kWarnLocalOnlyDropped c: label',
          '$kWarnLocalOnlyDropped Broken: json',
        ],
      );
      final dns = dnsToBackup(
        servers: state.dnsServers,
        rules: state.dnsRules,
        dnsFinal: '',
        strategy: '',
        warnings: [],
      );
      expect(dns.rules.map((r) => r.kind), ['user', 'preset']);
    });

    test('валидатор схемы не пропускает чужую форму', () {
      final schemaFile = File(_schemaPath);
      if (!schemaFile.existsSync()) {
        markTestSkipped('контракт не синхронизирован');
        return;
      }
      final schema = jsonDecode(schemaFile.readAsStringSync()) as Map<String, dynamic>;
      final bad = {
        'lx_backup': 1,
        'exported_by': {'app': 'lxbox'},
        'exported_at': '2026-09-14T00:00:00Z',
        'sources': [
          {'kind': 'subscription'},
          {'kind': 'server', 'origin': {'kind': 'ftp', 'raw': 'x'}},
        ],
        'rules': [
          {'kind': 'json', 'enabled': true},
        ],
      };
      final errors = validateJsonSchema(bad, schema);
      expect(errors.join('\n'), allOf(contains('lx_backup'), contains('"url"'), contains('ftp'), contains('json')));
      for (final f in Directory('contract/corpus/backup').listSync().whereType<File>()) {
        final name = f.path.split('/').last;
        if (!name.startsWith('v10_') || !name.endsWith('.backup.json')) continue;
        expect(validateJsonSchema(jsonDecode(f.readAsStringSync()), schema), isEmpty,
            reason: '$name — файл корпуса 1.0 обязан проходить схему');
      }
    });
  });
}

Matcher _deepEquals(Object? want) =>
    predicate<Object?>((got) => deepEqualsJson(got, want), 'deep-equals $want');
