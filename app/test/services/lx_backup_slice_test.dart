import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/chain_record.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/import_rule.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_sections.dart';
import 'package:lxbox/models/record_codec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/models/subscription_meta.dart';
import 'package:lxbox/services/dns/dns_backup.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/lx_backup_slice.dart';

/// §439 §1.3 — LX Backup 1.0 = срез записи хранения одной таблицей полей
/// (`lx_backup_slice.dart`): поле контракта едет, настройка LxBox без дома в
/// 1.0 срезается одним `backup_local_only_dropped` на сущность, рантайм и
/// маркеры — молча. Флаг Л2 `declared` снимает срез с поля: оно едет, импорт
/// его знает и применяет.

const _url = 'https://example-1.com/sub';
const _uri = 'vless://11111111-1111-1111-1111-111111111111@example-2.com:443'
    '?type=tcp&security=tls&sni=example-2.com#Tokyo';
const _memberUri = 'trojan://secret@example-3.com:443#de-1';

const _importRules = [
  ImportRule(
    conditions: [
      ImportRuleCondition(path: 'tag', op: ImportRuleOperator.contains, pattern: 'NL'),
    ],
    action: ImportRuleAction.disable,
  ),
];

const _flags = DetourPolicy(registerDetourServers: true, useDetourServers: false);

SubscriptionServers _subscription({
  DetourPolicy detourPolicy = DetourPolicy.defaults,
  List<ImportRule> importRules = const [],
  bool importRulesEnabled = true,
  SubscriptionOnUpdateAction onUpdateAction = SubscriptionOnUpdateAction.rebuild,
}) =>
    SubscriptionServers(
      id: 'sub-1',
      name: 'Provider',
      enabled: true,
      tagPrefix: 'PR',
      detourPolicy: detourPolicy,
      url: _url,
      importRules: importRules,
      importRulesEnabled: importRulesEnabled,
      onUpdateAction: onUpdateAction,
    );

/// Состояние со всеми настройками LxBox из §1.3, отличными от умолчания.
({
  List<ServerList> lists,
  List<SourceChain> chains,
  List<CustomRule> rules,
  List<DnsServerRef> dnsServers,
}) _richState() => (
      lists: [
        _subscription(
          detourPolicy: _flags.copyWith(overrideDetour: NodeLink(tag: 'vpn-1')),
          importRules: _importRules,
          importRulesEnabled: false,
          onUpdateAction: SubscriptionOnUpdateAction.reload,
        ),
        UserServer(
          id: 'srv-1',
          name: '',
          enabled: true,
          tagPrefix: 'JP',
          detourPolicy: _flags,
          rawBody: _uri,
        ),
        FolderServers(
          id: 'fold-1',
          name: 'EU',
          enabled: true,
          tagPrefix: 'EU',
          detourPolicy: _flags,
          createdAt: DateTime.utc(2026, 9, 1),
          pingUrl: 'https://example-4.com/204',
          pingTimeoutMs: 2500,
          members: [FolderMember(raw: _memberUri)],
        ),
      ],
      chains: const [SourceChain(tag: 'relay', label: 'Relay', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')])],
      rules: [
        CustomRuleSrs(
          id: 'r-geo',
          name: 'Geo',
          srsUrl: 'https://example-5.com/geo.srs',
          outbound: 'vpn-1',
          orderNum: 1000,
          updateIntervalHours: 720,
        ),
      ],
      dnsServers: const [
        DnsServerInline(
          enabled: true,
          tag: 'my-doh',
          body: {'type': 'https', 'server': 'example-6.com'},
          description: 'Office',
        ),
        DnsServerTemplate(
          enabled: true,
          tag: 'google_doh',
          varValues: {'dns_ip': '8.8.4.4'},
        ),
      ],
    );

Future<LxBackupExport> _export(
  List<ServerList> lists, {
  List<SourceChain> chains = const [],
  List<CustomRule> rules = const [],
  List<DnsServerRef> dnsServers = const [],
  List<DnsRuleRef> dnsRules = const [],
  List<LxBackupWarning>? dnsWarnings,
}) =>
    buildLxBackup(
      lists: lists,
      rules: rules,
      vars: const {},
      chains: chains,
      dns: dnsToBackup(
        servers: dnsServers,
        rules: dnsRules,
        dnsFinal: '',
        strategy: '',
        warnings: dnsWarnings,
      ),
    );

Map<String, dynamic> _source(String json, String kind) =>
    ((jsonDecode(json) as Map)['sources'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['kind'] == kind);

List<String> _lines(List<LxBackupWarning> warnings) =>
    [for (final w in warnings) '${w.code} ${w.detail}'];

/// Импорт теми же чистыми функциями, что экран бэкапа.
({LxBackupFile file, List<ServerList> lists, List<SourceChain> chains})
    _import(List<ServerList> lists, String raw) {
  final file = parseLxBackup(raw, knownOutbounds: const {'vpn-1'});
  final subs = mergeBackupSubscriptions(lists, file.subscriptions);
  final servers = mergeBackupServers(
    subs.lists,
    file.servers,
    folders: file.folders,
    sourceIds: subs.ids,
    addedSources: subs.added,
    sourceDetours: subs.detours,
  );
  return (
    file: file,
    lists: servers.lists,
    chains: resolveBackupChainHops(file, servers.lists, servers.folderIds),
  );
}

/// Таблица, в которой все настройки LxBox объявлены контрактом (Л2).
List<BackupField> _allSettingsDeclared() => [
      for (final f in kBackupFields)
        f.fate == BackupFieldFate.setting
            ? BackupField(f.record, f.key, f.fate, declared: true)
            : f,
    ];

void main() {
  tearDown(() => overrideBackupFieldsForTesting(null));

  group('срез по таблице', () {
    test('настройки не по умолчанию — одно предупреждение на сущность, в файл '
        'не едут', () async {
      final s = _richState();
      final out = await _export(s.lists, chains: s.chains, rules: s.rules);
      expect(_lines(out.warnings), [
        '$kWarnLocalOnlyDropped Provider: detour_policy, import_rules, '
            'import_rules_enabled, on_update_action',
        '$kWarnLocalOnlyDropped Tokyo: detour_policy, tag_policy',
        '$kWarnLocalOnlyDropped EU: detour_policy, ping_url, ping_timeout_ms',
        '$kWarnLocalOnlyDropped relay: label',
        '$kWarnLocalOnlyDropped Geo: update_interval_hours',
      ]);
      final sub = _source(out.json, 'subscription');
      for (final key in [
        'detour_policy',
        'import_rules',
        'import_rules_enabled',
        'on_update_action',
      ]) {
        expect(sub.containsKey(key), isFalse, reason: key);
      }
      // Ссылка detour — поле контракта: едет.
      expect(sub['detour'], {'tag': 'vpn-1'});
      expect(_source(out.json, 'server').containsKey('tag_policy'), isFalse);
      final folder = _source(out.json, 'folder');
      expect(folder.keys, isNot(contains('ping_url')));
      expect(folder.containsKey('created_at'), isFalse,
          reason: 'рантайм — молча');
    });

    test('умолчания, рантайм и маркер verbatim — без предупреждений', () async {
      final sub = SubscriptionServers(
        id: 'sub-1',
        name: 'Provider',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: _url,
        meta: const SubscriptionMeta(totalBytes: 1 << 30),
        lastUpdated: DateTime.utc(2026, 9, 1),
        lastUpdateStatus: UpdateStatus.failed,
        lastNodeCount: 12,
        consecutiveFails: 2,
      );
      final out = await _export(
        [sub],
        rules: [CustomRuleJson(id: 'r1', name: 'Raw', json: '{"action":"sniff"}')],
      );
      expect(out.warnings, isEmpty);
      final record = _source(out.json, 'subscription');
      for (final key in [
        'meta',
        'last_updated',
        'last_update_status',
        'last_node_count',
        'consecutive_fails',
      ]) {
        expect(record.containsKey(key), isFalse, reason: key);
      }
      final rule = ((jsonDecode(out.json) as Map)['rules'] as List).single as Map;
      expect(rule.containsKey('verbatim'), isFalse);
      expect(rule['body'], {'action': 'sniff'});
    });

    test('имя цепочки, равное тегу, и пустое — не потеря', () async {
      final out = await _export(const [], chains: const [
        SourceChain(tag: 'a', label: 'a', hops: [NodeLink(tag: 'x'), NodeLink(tag: 'y')]),
        SourceChain(tag: 'b', hops: [NodeLink(tag: 'x'), NodeLink(tag: 'y')]),
      ]);
      expect(out.warnings, isEmpty);
    });

    test('ключ записи вне таблицы срезается с названием', () {
      final stored = {
        ...chainToRecord(const SourceChain(tag: 'c', hops: [NodeLink(tag: 'x'), NodeLink(tag: 'y')])),
        'future_key': 1,
      };
      final slice = sliceBackupRecord(BackupRecord.chain, stored);
      expect(slice.record!.containsKey('future_key'), isFalse);
      expect(slice.dropped, ['future_key']);
    });

    test('таблица перечисляет все ключи записей кодека', () {
      final s = _richState();
      final sub = (s.lists[0] as SubscriptionServers).copyWith(
        meta: const SubscriptionMeta(totalBytes: 1),
        lastUpdated: DateTime.utc(2026),
        lastUpdateAttempt: DateTime.utc(2026),
        lastUpdateStatus: UpdateStatus.ok,
        lastNodeCount: 1,
        consecutiveFails: 1,
        disabledHashes: {'x': DateTime.utc(2026)},
        identity: const SubscriptionIdentityOverride(userAgent: 'ua'),
      );
      final folder = (s.lists[2] as FolderServers).copyWith(members: [
        FolderMember(
          raw: _memberUri,
          detour: NodeLink(tag: 'Tokyo'),
          sections: NodeSections.fromJson({
            'rules': [
              {
                'kind': 'inline',
                'name': 'n',
                'enabled': true,
                'body': {'outbound': '@self'},
              },
            ],
          }),
        ),
        FolderMember(raw: 'not a node'),
      ]);
      final server = (s.lists[1] as UserServer).copyWith(
        detourPolicy: _flags.copyWith(overrideDetour: NodeLink(tag: 'EU de-1')),
        sections: folder.members.first.sections,
      );
      Set<String> table(BackupRecord kind) => {
            for (final f in kBackupFields)
              if (f.record == kind && !f.key.startsWith('kind:')) f.key,
          };
      void covered(BackupRecord kind, Map<String, dynamic> record) {
        expect(table(kind), containsAll(record.keys), reason: kind.name);
      }

      covered(BackupRecord.subscription, sourceToRecord(sub));
      covered(BackupRecord.server, sourceToRecord(server));
      final folderRecord = sourceToRecord(folder);
      covered(BackupRecord.folder, folderRecord);
      for (final n in folderRecord['nodes'] as List) {
        covered(BackupRecord.folderNode, (n as Map).cast<String, dynamic>());
      }
      covered(
          BackupRecord.chain,
          chainToRecord(const SourceChain(
            tag: 'c',
            label: 'L',
            enabled: false,
            hops: [NodeLink(tag: 'x')],
            idleTimeout: '1m',
            stripEvasion: true,
          )));
      for (final r in [
        ...s.rules,
        CustomRuleInline(
          id: 'i',
          name: 'I',
          domains: const ['a.example'],
          orderNum: 1,
          dns: const RuleDns(enabled: true, serverTag: 'my-doh'),
          resolve: const RuleResolve(serverTag: 'my-doh'),
        ),
        CustomRuleJson(id: 'j', name: 'J', json: '{"action":"sniff"}'),
        CustomRulePreset(
            id: 'p', name: 'P', presetId: 'ru', varsValues: const {'a': 'b'}),
      ]) {
        covered(BackupRecord.rule, ruleToRecord(r));
      }
      for (final d in [
        ...s.dnsServers,
        const DnsServerPreset(
            enabled: false, tag: 'y', presetId: 'ru', description: 'd'),
      ]) {
        covered(BackupRecord.dnsServer, dnsServerToRecord(d));
      }
      for (final r in const <DnsRuleRef>[
        DnsRuleInline(name: 'n', rule: {'server': 'x'}, enabled: false),
        DnsRulePreset(presetId: 'ru', enabled: true),
      ]) {
        covered(BackupRecord.dnsRule, dnsRuleToRecord(r));
      }
    });

    test('секции узла и члены папки: потеря путём у носителя', () async {
      final sections = NodeSections.fromJson({
        'dns': {
          'servers': [
            {
              'kind': 'user',
              'tag': '@{self}-dns',
              'enabled': true,
              'body': {'type': 'udp', 'server': '100.100.100.100'},
              'description': 'tailnet',
            },
          ],
        },
      })!;
      final out = await _export([
        UserServer(
          id: 'srv-1',
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          rawBody: _uri,
          sections: sections,
        ),
      ]);
      expect(_lines(out.warnings), [
        '$kWarnLocalOnlyDropped Tokyo: '
            'sections.dns.servers[@{self}-dns].description',
      ]);
      final dns = (_source(out.json, 'server')['sections'] as Map)['dns'] as Map;
      expect((dns['servers'] as List).single, isNot(contains('description')));
    });

    test('DNS: description и vars сервера названы у каждой записи, srs-правило '
        'не пишется и названо, template-правило — молча', () async {
      final warnings = <LxBackupWarning>[];
      final out = await _export(
        const [],
        dnsServers: _richState().dnsServers,
        dnsRules: const [
          DnsRuleSrs(name: 'Geo', id: 's1'),
          DnsRuleTemplate(name: 'Default', enabled: true),
          DnsRuleInline(name: 'corp', rule: {'server': 'my-doh'}),
        ],
        dnsWarnings: warnings,
      );
      expect(_lines(warnings), [
        '$kWarnLocalOnlyDropped dns: my-doh: description',
        '$kWarnLocalOnlyDropped dns: google_doh: vars',
        '$kWarnLocalOnlyDropped dns: Geo: srs',
      ]);
      final dns = (jsonDecode(out.json) as Map)['dns'] as Map;
      expect([for (final r in dns['rules'] as List) (r as Map)['kind']], ['user']);
    });
  });

  group('Л2: declared — поле едет и применяется', () {
    setUp(() => overrideBackupFieldsForTesting(_allSettingsDeclared()));

    test('экспорт пишет объявленные настройки без предупреждений', () async {
      final s = _richState();
      final dnsWarnings = <LxBackupWarning>[];
      final out = await _export(s.lists,
          chains: s.chains,
          rules: s.rules,
          dnsServers: s.dnsServers,
          dnsRules: const [DnsRuleSrs(name: 'Geo', id: 's1')],
          dnsWarnings: dnsWarnings);
      expect(out.warnings, isEmpty);
      expect(dnsWarnings, isEmpty);
      final sub = _source(out.json, 'subscription');
      expect(sub['detour_policy'], sourceToRecord(s.lists[0])['detour_policy']);
      expect(sub['on_update_action'], 'reload');
      expect(sub['import_rules_enabled'], false);
      expect(sub['import_rules'], hasLength(1));
      expect(_source(out.json, 'server')['tag_policy'], {'prefix': 'JP '});
      expect(_source(out.json, 'folder')['ping_timeout_ms'], 2500);
      expect(_source(out.json, 'chain')['label'], 'Relay');
      final doc = jsonDecode(out.json) as Map;
      expect(((doc['rules'] as List).single as Map)['update_interval_hours'], 720);
      final dns = doc['dns'] as Map;
      expect(((dns['servers'] as List).first as Map)['description'], 'Office');
      expect(((dns['servers'] as List).last as Map)['vars'], {'dns_ip': '8.8.4.4'});
      expect(((dns['rules'] as List).single as Map)['kind'], 'srs');
    });

    test('импорт в пустое состояние: не неизвестны и применены', () async {
      final s = _richState();
      final out = await _export(s.lists,
          chains: s.chains, rules: s.rules, dnsServers: s.dnsServers);
      final got = _import(const [], out.json);
      expect(got.file.warnings, isEmpty);

      final sub = got.lists.whereType<SubscriptionServers>().single;
      final want = s.lists[0] as SubscriptionServers;
      expect(sub.detourPolicy, want.detourPolicy);
      expect(sub.importRules, want.importRules);
      expect(sub.importRulesEnabled, isFalse);
      expect(sub.onUpdateAction, SubscriptionOnUpdateAction.reload);

      final server = got.lists.whereType<UserServer>().single;
      expect(server.tagPrefix, 'JP');
      expect(server.detourPolicy, _flags);

      final folder = got.lists.whereType<FolderServers>().single;
      expect(folder.detourPolicy, _flags);
      expect(folder.pingUrl, 'https://example-4.com/204');
      expect(folder.pingTimeoutMs, 2500);

      expect(got.chains.single.label, 'Relay');
      expect((got.file.rules.single as CustomRuleSrs).updateIntervalHours, 720);
      expect(got.file.dns!.servers, s.dnsServers);
    });

    test('совпавшие источники берут объявленные настройки из файла', () async {
      final s = _richState();
      final out = await _export(s.lists);
      final local = <ServerList>[
        _subscription(),
        UserServer(
          id: 'srv-local',
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          rawBody: _uri,
        ),
        FolderServers(
          id: 'fold-1',
          name: 'EU',
          enabled: true,
          tagPrefix: 'EU',
          detourPolicy: DetourPolicy.defaults,
          members: [FolderMember(raw: _memberUri)],
        ),
      ];
      final got = _import(local, out.json);
      expect(got.lists, hasLength(3), reason: 'слияние, а не доливка');
      final sub = got.lists[0] as SubscriptionServers;
      expect(sub.detourPolicy, (s.lists[0] as SubscriptionServers).detourPolicy);
      expect(sub.importRules, _importRules);
      expect(sub.onUpdateAction, SubscriptionOnUpdateAction.reload);
      final server = got.lists[1] as UserServer;
      expect(server.id, 'srv-local');
      expect(server.tagPrefix, 'JP');
      expect(server.detourPolicy, _flags);
      final folder = got.lists[2] as FolderServers;
      expect(folder.detourPolicy, _flags);
      expect(folder.pingTimeoutMs, 2500);
    });
  });

  group('слияние подписки по URL: поля стороны', () {
    final local = _subscription(
      detourPolicy: _flags,
      importRules: _importRules,
      importRulesEnabled: false,
      onUpdateAction: SubscriptionOnUpdateAction.none,
    );
    // Файл стороны, которая полей LxBox не носит (лаунчер): подписка тем же
    // URL, без detour_policy/import_rules/on_update_action.
    final launcherFile = jsonEncode({
      'lx_backup': 2,
      'exported_by': {'app': 'launcher', 'version': '1.6.0'},
      'exported_at': '2026-09-15T00:00:00Z',
      'sources': [
        {
          'kind': 'subscription',
          'id': 'sub-file',
          'name': 'From launcher',
          'enabled': true,
          'url': _url,
          'update': {'interval_hours': 6},
        },
      ],
    });

    void expectKept(ServerList merged) {
      final sub = merged as SubscriptionServers;
      expect(sub.name, 'From launcher', reason: 'поля контракта применены');
      expect(sub.updateIntervalHours, 6);
      expect(sub.detourPolicy, _flags, reason: 'detour_policy');
      expect(sub.importRules, _importRules, reason: 'import_rules');
      expect(sub.importRulesEnabled, isFalse, reason: 'import_rules_enabled');
      expect(sub.onUpdateAction, SubscriptionOnUpdateAction.none,
          reason: 'on_update_action');
    }

    test('поля не объявлены: отсутствие не сбрасывает значение приёмника', () {
      final got = _import([local], launcherFile);
      expect(got.file.warnings, isEmpty);
      expectKept(got.lists.single);
    });

    test('поля объявлены, но в файле их нет: значение приёмника остаётся', () {
      overrideBackupFieldsForTesting(_allSettingsDeclared());
      expectKept(_import([local], launcherFile).lists.single);
    });
  });
}
