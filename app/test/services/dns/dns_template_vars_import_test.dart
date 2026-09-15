import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/services/dns/dns_backup.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/lx_backup_import.dart';
import 'package:lxbox/services/record_vars.dart';

// §441 (SPEC 128 контракта) — импорт значений переменных записи:
// Н8 (корневые `dns_<tag>_<var>` → запись сервера файла), слияние §5.2
// (наложение по именам, Н2/Н4 против шаблона приёмника), Н9 (неизвестная
// цель маршрута выключает DNS-сервер), Н2/Н4 у `rules[kind=preset].vars`.

/// Объявления приёмника с умолчаниями, как у лаунчера в кейсе корпуса
/// `v10_dns_template_vars` (SPEC 128 §9.1): `google_dot.outbound` =
/// `proxy-out`, пресет `russian` с `out` = `direct-out`.
final _decls = RecordVarDecls.fromJson({
  'dns_options': {
    'servers': [
      {
        'vars': [
          {'name': 'outbound', 'type': 'outbound', 'default_value': 'direct-out'},
          {'name': 'dns_ip', 'type': 'enum', 'default_value': '8.8.8.8'},
        ],
        'server': {'type': 'udp', 'tag': 'google_udp'},
      },
      {
        'vars': [
          {'name': 'outbound', 'type': 'outbound', 'default_value': 'proxy-out'},
          {'name': 'dns_ip', 'type': 'enum', 'default_value': '8.8.8.8'},
        ],
        'server': {'type': 'tls', 'tag': 'google_dot'},
      },
      {
        'vars': [
          {'name': 'outbound', 'type': 'outbound', 'default_value': 'proxy-out'},
        ],
        'server': {'type': 'tls', 'tag': 'cloudflare_dot'},
      },
      {
        'vars': [
          {'name': 'outbound', 'type': 'outbound', 'default_value': 'direct-out'},
          {'name': 'dom_resolver', 'type': 'dns_servers', 'default_value': 'google_udp'},
        ],
        'server': {'type': 'tls', 'tag': 'safe_dns_dot'},
      },
      {
        'vars': [
          {'name': 'outbound', 'type': 'outbound', 'default_value': 'vpn-1'},
        ],
        'server': {'type': 'https', 'tag': 'quad9_doh'},
      },
    ],
  },
  'presets': [
    {
      'id': 'russian',
      'vars': [
        {'name': 'out', 'type': 'outbound', 'default': 'direct-out'},
        {'name': 'dns_ip', 'type': 'enum', 'default': '77.88.8.8'},
      ],
    },
  ],
});

String _file(Map<String, dynamic> body, {int version = 2}) => jsonEncode({
      'lx_backup': version,
      'exported_by': {'app': 'launcher', 'version': '1.6.0'},
      'exported_at': '2026-09-15T00:00:00Z',
      ...body,
    });

LxImportReceiver _receiver({
  List<DnsServerRef> servers = const [],
  RecordVarDecls decls = RecordVarDecls.none,
  bool withTargets = true,
}) =>
    LxImportReceiver(
      directions: withTargets
          ? const [Direction(tag: 'vpn-1', label: 'VPN 1')]
          : const [],
      receiverTargets: withTargets ? const {'proxy', 'direct'} : const {},
      dns: LxDns(servers: servers),
      recordVars: decls,
    );

Map<String, DnsServerRef> _byTag(List<DnsServerRef> servers) =>
    {for (final s in servers) s.tag: s};

Map<String, String> _varsOf(DnsServerRef? s) =>
    s is DnsServerTemplate ? s.varValues : const {};

List<String> _reasons(LxBackupFile f, String code) => [
      for (final w in f.warnings)
        if (w.code == code) '${w.reason}:${w.detail}',
    ];

void main() {
  group('SPEC 128 §9.1 — сценарий кейса v10_dns_template_vars', () {
    late LxImportPlan plan;

    setUpAll(() {
      final raw = _file({
        'dns': {
          'servers': [
            {
              'kind': 'template',
              'tag': 'google_udp',
              'enabled': true,
              'vars': {'outbound': 'vpn-1', 'dns_ip': '8.8.4.4', 'legacy_x': '1'},
            },
            {
              'kind': 'template',
              'tag': 'google_dot',
              'enabled': false,
              'vars': {'outbound': 'proxy-out'},
            },
            {'kind': 'template', 'tag': 'cloudflare_dot', 'enabled': true},
            {
              'kind': 'template',
              'tag': 'safe_dns_dot',
              'enabled': true,
              'vars': {'outbound': 'ghost-vpn'},
            },
            {
              'kind': 'template',
              'tag': 'no_such_server',
              'enabled': true,
              'vars': {'outbound': 'vpn-1'},
            },
            {
              'kind': 'user',
              'tag': 'my-doh',
              'enabled': true,
              'body': {'type': 'https', 'server': '1.1.1.1', 'detour': 'ghost-vpn'},
            },
          ],
        },
        'vars': {
          'dns_cloudflare_dot_outbound': 'vpn-1',
          'dns_google_udp_outbound': 'direct-out',
          'dns_quad9_doh_outbound': 'vpn-1',
        },
        'rules': [
          {
            'kind': 'preset',
            'ref': 'russian',
            'enabled': true,
            'num': 960,
            'vars': {'out': 'direct-out', 'dns_ip': '77.88.8.1', 'bogus': 'x'},
          },
        ],
      });
      plan = planLxBackupImport(
        raw,
        _receiver(
          decls: _decls,
          servers: const [
            DnsServerTemplate(
              enabled: true,
              tag: 'google_dot',
              varValues: {'outbound': 'vpn-1', 'dns_ip': '8.8.4.4'},
            ),
          ],
        ),
      );
    });

    test('записи DNS: vars, enabled', () {
      final got = _byTag(plan.dns!.servers);
      expect(_varsOf(got['google_udp']), {'outbound': 'vpn-1', 'dns_ip': '8.8.4.4'},
          reason: 'Н5: все значения; legacy_x снят (Н2)');
      expect(got['google_dot']!.enabled, isTrue, reason: '§5.2: enabled локальный');
      expect(_varsOf(got['google_dot']), {'dns_ip': '8.8.4.4'},
          reason: 'наложение outbound: proxy-out = умолчание → снят (Н4); '
              'dns_ip приёмника не тронут');
      expect(_varsOf(got['cloudflare_dot']), {'outbound': 'vpn-1'},
          reason: 'Н8: запись без vars получает корневое значение');
      expect(got['safe_dns_dot']!.enabled, isFalse, reason: 'Н9');
      expect(_varsOf(got['safe_dns_dot']), {'outbound': 'ghost-vpn'},
          reason: 'Н9: значение остаётся');
      expect(got.containsKey('no_such_server'), isFalse, reason: '§5.2');
      expect(got['my-doh']!.enabled, isFalse, reason: 'Н9 у kind: user');
    });

    test('корневых dns_* нет, пресет нормализован', () {
      expect(plan.file.vars.keys.where((k) => k.startsWith('dns_')), isEmpty);
      final russian = plan.rules.whereType<CustomRulePreset>().single;
      expect(russian.varsValues, {'dns_ip': '77.88.8.1'});
    });

    test('предупреждения и причины', () {
      final f = plan.file;
      expect(_reasons(f, kWarnVarSkipped)..sort(), [
        'no_record:dns_quad9_doh_outbound',
        'superseded:dns_google_udp_outbound',
        'undeclared:dns:google_udp.vars.legacy_x',
        'undeclared:preset:russian.vars.bogus',
      ]);
      expect(f.warnings.where((w) => w.code == kWarnUnknownOutbound).map((w) => w.detail),
          unorderedEquals(['dns:safe_dns_dot → ghost-vpn', 'dns:my-doh → ghost-vpn']));
      expect(
          f.warnings.where((w) => w.code == kWarnDnsEntrySkipped).map((w) => w.detail),
          ['dns.servers: template:no_such_server']);
    });
  });

  group('Л5: vars у DNS-записи не того вида', () {
    test('user и preset — backup_unknown_field, ключ не применяется; у template — поле',
        () {
      final f = decodeLxBackup(
        _file({
          'sources': [
            {
              'kind': 'server',
              'id': 'srv-1',
              'tag': 'home-ts',
              'enabled': true,
              'body': {'type': 'socks', 'server': '192.0.2.1', 'server_port': 1080},
              'sections': {
                'dns': {
                  'servers': [
                    {
                      'kind': 'user',
                      'tag': 'ts-dns',
                      'enabled': true,
                      'body': {'type': 'udp', 'server': '100.100.100.100'},
                      'vars': {'outbound': 'vpn-1'},
                    },
                  ],
                },
              },
            },
          ],
          'dns': {
            'servers': [
              {
                'kind': 'user',
                'tag': 'my-doh',
                'enabled': true,
                'body': {'type': 'https', 'server': '1.1.1.1'},
                'vars': {'outbound': 'vpn-1'},
              },
              {
                'kind': 'preset',
                'ref': 'ru-direct:dns_ru',
                'enabled': true,
                'vars': {'dns_ip': '77.88.8.1'},
              },
              {
                'kind': 'template',
                'tag': 'google_udp',
                'enabled': true,
                'vars': {'dns_ip': '8.8.4.4'},
              },
            ],
          },
        }),
        recordVars: _decls,
      );
      expect(
        [
          for (final w in f.warnings)
            if (w.code == kWarnUnknownField) w.detail,
        ],
        [
          'dns.servers[#2].vars',
          'dns.servers[my-doh].vars',
          'sources[home-ts].sections.dns.servers[ts-dns].vars',
        ],
      );
      final servers = f.dns!.servers;
      expect(servers, hasLength(3));
      expect((servers[0] as DnsServerInline).body,
          {'type': 'https', 'server': '1.1.1.1'});
      expect(servers[1], isA<DnsServerPreset>());
      expect(_varsOf(servers[2]), {'dns_ip': '8.8.4.4'});
    });
  });

  group('Н8: корневые dns_<tag>_<var>', () {
    LxBackupFile decode(Map<String, dynamic> body, {int version = 2}) =>
        decodeLxBackup(_file(body, version: version), recordVars: _decls);

    test('кандидата нет — not_portable', () {
      final f = decode({
        'vars': {'dns_custom_thing': 'x'},
      });
      expect(_reasons(f, kWarnVarSkipped), ['not_portable:dns_custom_thing']);
    });

    test('запись без vars — перенос; два имени одного сервера — оба', () {
      final f = decode({
        'dns': {
          'servers': [
            {'kind': 'template', 'tag': 'google_udp', 'enabled': true},
          ],
        },
        'vars': {
          'dns_google_udp_outbound': 'vpn-1',
          'dns_google_udp_dns_ip': '8.8.4.4',
        },
      });
      expect(_varsOf(f.dns!.servers.single),
          {'outbound': 'vpn-1', 'dns_ip': '8.8.4.4'});
      expect(f.warnings.where((w) => w.code == kWarnVarSkipped), isEmpty);
      expect(f.vars, isEmpty);
    });

    test('у записи свои vars — superseded, запись побеждает', () {
      final f = decode({
        'dns': {
          'servers': [
            {
              'kind': 'template',
              'tag': 'google_udp',
              'vars': {'dns_ip': '8.8.4.4'},
            },
          ],
        },
        'vars': {'dns_google_udp_outbound': 'vpn-1'},
      });
      expect(_varsOf(f.dns!.servers.single), {'dns_ip': '8.8.4.4'});
      expect(_reasons(f, kWarnVarSkipped), ['superseded:dns_google_udp_outbound']);
    });

    test('записи нет — no_record; шаблона нет — прежнее not_portable', () {
      final f = decode({
        'vars': {'dns_google_udp_outbound': 'vpn-1'},
      });
      expect(_reasons(f, kWarnVarSkipped), ['no_record:dns_google_udp_outbound']);
      final bare = decodeLxBackup(_file({
        'vars': {'dns_google_udp_outbound': 'vpn-1'},
      }));
      expect(_reasons(bare, kWarnVarSkipped), ['not_portable:dns_google_udp_outbound']);
    });

    test('файл 0.x: то же правило; vars ссылки 0.12 читаются', () {
      final f = decode({
        'dns': {
          'servers': [
            {'kind': 'template', 'name': 'google_udp', 'enabled': true},
            {
              'kind': 'template',
              'name': 'google_dot',
              'vars': {'dns_ip': '8.8.4.4'},
            },
          ],
        },
        'vars': {'dns_google_udp_outbound': 'vpn-1'},
      }, version: 1);
      final got = _byTag(f.dns!.servers);
      expect(_varsOf(got['google_udp']), {'outbound': 'vpn-1'});
      expect(_varsOf(got['google_dot']), {'dns_ip': '8.8.4.4'});
    });
  });

  group('§5.2 слияние и Н9', () {
    LxDns incoming(List<DnsServerRef> servers) => LxDns(servers: servers);

    test('записи не было: из файла, затем Н2/Н4', () {
      final warnings = <LxBackupWarning>[];
      final r = applyDnsBackup(
        incoming: incoming(const [
          DnsServerTemplate(enabled: false, tag: 'google_udp', varValues: {
            'outbound': 'direct-out',
            'dns_ip': '8.8.4.4',
            'old': 'x',
          }),
        ]),
        servers: const [],
        rules: const [],
        dnsFinal: '',
        strategy: '',
        recordVars: _decls,
        warnings: warnings,
      );
      final s = r.servers.single as DnsServerTemplate;
      expect(s.enabled, isFalse);
      expect(s.varValues, {'dns_ip': '8.8.4.4'});
      expect(warnings.map((w) => '${w.reason}:${w.detail}'),
          ['undeclared:dns:google_udp.vars.old']);
    });

    test('запись была: имена файла накладываются, прочие целы, своё необъявленное — молча',
        () {
      final warnings = <LxBackupWarning>[];
      final r = applyDnsBackup(
        incoming: incoming(const [
          DnsServerTemplate(
              enabled: true, tag: 'google_udp', varValues: {'outbound': 'vpn-1'}),
        ]),
        servers: const [
          DnsServerTemplate(enabled: false, tag: 'google_udp', varValues: {
            'dns_ip': '8.8.4.4',
            'stale': 'y',
          }),
        ],
        rules: const [],
        dnsFinal: '',
        strategy: '',
        recordVars: _decls,
        warnings: warnings,
      );
      final s = r.servers.single as DnsServerTemplate;
      expect(s.enabled, isFalse, reason: 'enabled локальный');
      expect(s.varValues, {'dns_ip': '8.8.4.4', 'outbound': 'vpn-1'});
      expect(warnings, isEmpty);
    });

    test('Н9 на совпавшей записи: неизвестная цель применена, сервер выключен',
        () {
      final warnings = <LxBackupWarning>[];
      final r = applyDnsBackup(
        incoming: incoming(const [
          DnsServerTemplate(
              enabled: true, tag: 'google_udp', varValues: {'outbound': 'vpn-9'}),
        ]),
        servers: const [
          DnsServerTemplate(
              enabled: true, tag: 'google_udp', varValues: {'outbound': 'vpn-1'}),
        ],
        rules: const [],
        dnsFinal: '',
        strategy: '',
        recordVars: _decls,
        knownTargets: const {'vpn-1', 'direct-out'},
        warnings: warnings,
      );
      final s = r.servers.single as DnsServerTemplate;
      expect(s.enabled, isFalse);
      expect(s.varValues, {'outbound': 'vpn-9'});
      expect(warnings.single.code, kWarnUnknownOutbound);
    });

    test('Н9: проверять нечем — цели не режутся; dns_server не проверяется', () {
      final r = applyDnsBackup(
        incoming: incoming(const [
          DnsServerTemplate(
              enabled: true, tag: 'safe_dns_dot', varValues: {'outbound': 'vpn-9'}),
          DnsServerInline(
              enabled: true, tag: 'u', body: {'type': 'udp', 'detour': 'vpn-9'}),
        ]),
        servers: const [],
        rules: const [],
        dnsFinal: '',
        strategy: '',
        recordVars: _decls,
      );
      expect(r.servers.every((s) => s.enabled), isTrue);

      final gated = applyDnsBackup(
        incoming: incoming(const [
          DnsServerTemplate(
              enabled: true,
              tag: 'safe_dns_dot',
              varValues: {'dom_resolver': 'ghost_dns'}),
        ]),
        servers: const [],
        rules: const [],
        dnsFinal: '',
        strategy: '',
        recordVars: _decls,
        knownTargets: const {'vpn-1', 'direct-out'},
      );
      expect(gated.servers.single.enabled, isTrue);
    });

    test('Н9 в плане: список целей не задан — не режется', () {
      final plan = planLxBackupImport(
        _file({
          'dns': {
            'servers': [
              {
                'kind': 'user',
                'tag': 'my-doh',
                'enabled': true,
                'body': {'type': 'https', 'server': '1.1.1.1', 'detour': 'ghost'},
              },
            ],
          },
        }),
        _receiver(withTargets: false),
      );
      expect(plan.knownTargets, isNull);
      expect(plan.dns!.servers.single.enabled, isTrue);
    });
  });
}
