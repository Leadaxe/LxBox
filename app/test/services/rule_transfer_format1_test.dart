import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/record_codec.dart';
import 'package:lxbox/services/rule_transfer.dart';

/// §439 §3.4 — файл правил (§396): экспорт пишет `format: 2` — записи хранения
/// 1.0 со всеми полями LxBox (`verbatim`, `update_interval_hours`,
/// `description`, `vars` сервера); `format: 1` (форма хранения 2.23.2) читают
/// замороженные читатели `legacy_form_v0.dart`. Какой читатель берётся, решает
/// `format` конверта, а не вид элемента.

final _template = WizardTemplate.fromJson({
  'dns_options': {
    'servers': [
      {
        'enabled': true,
        'server': {'tag': 'google_udp', 'type': 'udp'},
      },
    ],
    'rules': [
      {'name': 'Default', 'server': 'google_udp'},
    ],
  },
  'selectable_rules': [
    {
      'preset_id': 'block-ads',
      'ui': {'label': 'Block Ads', 'num': 960},
      'rule': {'rule_set': 'ads', 'action': 'reject'},
    },
  ],
});

const _directions = {'vpn-1'};
const _dnsTags = {'my-doh'};

SanitizedImportRule _rule(dynamic entry, int format) => sanitizeImportedRule(
      entry,
      directionTags: _directions,
      dnsServerTags: _dnsTags,
      template: _template,
      format: format,
    );

SanitizedImportDnsItem<DnsServerRef> _server(dynamic entry, int format) =>
    sanitizeImportedDnsServer(entry,
        existingTags: const {},
        templateServerTags: const {'google_udp'},
        format: format);

SanitizedImportDnsItem<DnsRuleRef> _dnsRule(dynamic entry, int format) =>
    sanitizeImportedDnsRule(entry,
        existingRules: const [], template: _template, format: format);

/// Запись правила без `id` (импорт выдаёт новый) — для сравнения моделей.
Map<String, dynamic> _withoutId(CustomRule r) => ruleToRecord(r)..remove('id');

void main() {
  group('format: 2 — круг экспорт → разбор → санация', () {
    final rules = <CustomRule>[
      CustomRuleInline(
        id: 'r-corp',
        name: 'Corp',
        domainSuffixes: const ['.corp.example-1.com'],
        ports: const ['443'],
        packages: const ['com.example.app'],
        wifiSsids: const ['Office'],
        outbound: 'vpn-1',
        orderNum: 1000,
        dns: const RuleDns(enabled: true, serverTag: 'my-doh', forceIpv4: true),
        resolve: const RuleResolve(serverTag: 'my-doh'),
      ),
      CustomRuleSrs(
        id: 'r-geo',
        name: 'Geo',
        srsUrls: const [
          'https://example-2.com/a.srs',
          'https://example-2.com/b.srs',
        ],
        outbound: 'vpn-1',
        orderNum: 1001,
        updateIntervalHours: 720,
      ),
      CustomRuleJson(
        id: 'r-sniff',
        name: 'Sniff',
        json: '{"action":"sniff","inbound":["tun-in"]}',
        orderNum: 1002,
      ),
    ];
    const dnsServers = <DnsServerRef>[
      DnsServerInline(
        enabled: true,
        tag: 'office-dns',
        body: {'type': 'udp', 'server': '10.0.0.1'},
        description: 'Office',
      ),
      DnsServerTemplate(
          enabled: false, tag: 'google_udp', varValues: {'dns_ip': '8.8.4.4'}),
    ];
    const dnsRules = <DnsRuleRef>[
      DnsRuleInline(name: 'corp', rule: {'server': 'office-dns'}, enabled: false),
      DnsRuleSrs(
        name: 'geo',
        id: 'ds-geo',
        body: {'server': 'office-dns'},
        srsUrl: 'https://example-2.com/geo.srs',
      ),
    ];

    late RulesImportContents contents;
    setUp(() {
      contents = parseRulesImport(buildRulesExport(rules,
          appVersion: '2.23.3+22303',
          dnsServers: dnsServers,
          dnsRules: dnsRules));
    });

    test('конверт: format 2, элементы — записи хранения', () {
      expect(contents.format, kRulesExportFormatVersion);
      expect(kRulesExportFormatVersion, 2);
      expect(contents.rawRules, [for (final r in rules) ruleToRecord(r)]);
      expect(contents.rawDnsServers,
          [for (final s in dnsServers) dnsServerToRecord(s)]);
      expect(contents.rawDnsRules, [for (final r in dnsRules) dnsRuleToRecord(r)]);
      final geo = contents.rawRules[1] as Map;
      expect(geo['update_interval_hours'], 720);
      expect(geo['refs'], hasLength(2));
      expect((contents.rawRules[2] as Map)['verbatim'], isTrue);
    });

    test('правила возвращаются теми же, id новый, srs выключен до загрузки', () {
      for (var i = 0; i < rules.length; i++) {
        final s = _rule(contents.rawRules[i], contents.format);
        expect(s.rejectReason, isNull, reason: rules[i].name);
        expect(s.warnings, isEmpty, reason: rules[i].name);
        final got = s.rule!;
        expect(got.id, isNot(rules[i].id));
        final want = rules[i] is CustomRuleSrs
            ? rules[i].withEnabled(false)
            : rules[i];
        expect(_withoutId(got), _withoutId(want), reason: rules[i].name);
      }
      final json = _rule(contents.rawRules[2], contents.format).rule!;
      expect(json, isA<CustomRuleJson>(), reason: 'verbatim держит сырое тело');
      expect(jsonDecode((json as CustomRuleJson).json),
          {'action': 'sniff', 'inbound': ['tun-in']});
      expect(
          (_rule(contents.rawRules[1], contents.format).rule! as CustomRuleSrs)
              .updateIntervalHours,
          720);
    });

    test('DNS-серверы и правила — те же модели со всеми полями LxBox', () {
      expect(
          [for (final e in contents.rawDnsServers) _server(e, contents.format).item],
          dnsServers);
      final corp = _dnsRule(contents.rawDnsRules[0], contents.format);
      expect(corp.item, dnsRules[0]);
      final geo = _dnsRule(contents.rawDnsRules[1], contents.format).item!
          as DnsRuleSrs;
      expect(geo.id, isNot('ds-geo'), reason: 'кэш .srs у получателя свой');
      expect(geo.copyWith(id: 'ds-geo'), dnsRules[1]);
    });
  });

  group('format: 1 — форма хранения 2.23.2', () {
    Map<String, dynamic> file1({
      List<Map<String, dynamic>> rules = const [],
      List<Map<String, dynamic>> dnsServers = const [],
      List<Map<String, dynamic>> dnsRules = const [],
    }) =>
        {
          'app': 'lxbox',
          'kind': 'rules',
          'format': kRulesFormatLegacy,
          'created_at': '2026-09-01T00:00:00Z',
          'rules': rules.isEmpty
              ? [
                  {'kind': 'inline', 'name': 'filler'},
                ]
              : rules,
          'dns_servers': ?(dnsServers.isEmpty ? null : dnsServers),
          'dns_rules': ?(dnsRules.isEmpty ? null : dnsRules),
        };

    RulesImportContents parse(Map<String, dynamic> doc) =>
        parseRulesImport(jsonEncode(doc));

    test('правила всех видов читаются в модели, target — запасное имя цели', () {
      final c = parse(file1(rules: [
        {
          'id': 'old-1',
          'kind': 'inline',
          'name': 'Legacy inline',
          'enabled': true,
          'num': 5,
          'domainSuffixes': ['.example-1.com'],
          'ipIsPrivate': true,
          'target': 'vpn-1',
          'dns': {'enabled': true, 'serverTag': 'my-doh'},
        },
        {
          'kind': 'srs',
          'name': 'Legacy srs',
          'srsUrl': 'https://example-2.com/a.srs',
          'srsUrls': ['https://example-2.com/a.srs', 'https://example-2.com/b.srs'],
          'updateIntervalHours': 48,
          'outbound': 'vpn-1',
        },
        {'kind': 'json', 'name': 'Legacy json', 'json': '{"action":"sniff"}'},
      ]));
      expect(c.format, kRulesFormatLegacy);

      final inline = _rule(c.rawRules[0], c.format).rule! as CustomRuleInline;
      expect(inline.id, isNot('old-1'));
      expect(inline.name, 'Legacy inline');
      expect(inline.domainSuffixes, ['.example-1.com']);
      expect(inline.ipIsPrivate, isTrue);
      expect(inline.outbound, 'vpn-1');
      expect(inline.orderNum, 5);
      expect(inline.dns, const RuleDns(enabled: true, serverTag: 'my-doh'));

      final srs = _rule(c.rawRules[1], c.format).rule! as CustomRuleSrs;
      expect(srs.srsUrls,
          ['https://example-2.com/a.srs', 'https://example-2.com/b.srs']);
      expect(srs.updateIntervalHours, 48);
      expect(srs.enabled, isFalse);

      final json = _rule(c.rawRules[2], c.format).rule! as CustomRuleJson;
      expect(json.json, '{"action":"sniff"}');
    });

    test('пресет, чужой вид и поле неверного типа — отказ по элементу', () {
      final c = parse(file1(rules: [
        {'kind': 'preset', 'name': 'Ads', 'presetId': 'block-ads'},
        {'kind': 'user', 'name': 'Future'},
        {'kind': 'inline', 'name': 42},
      ]));
      expect(_rule(c.rawRules[0], c.format).rejectReason,
          ImportRuleRejectReason.presetNotTransferable);
      expect(_rule(c.rawRules[1], c.format).rejectReason,
          ImportRuleRejectReason.unsupportedEntry);
      expect(_rule(c.rawRules[2], c.format).rejectReason,
          ImportRuleRejectReason.unsupportedEntry);
    });

    test('DNS-серверы и правила формы kind-ref читаются в модели', () {
      final c = parse(file1(dnsServers: [
        {
          'enabled': true,
          'kind': 'inline',
          'tag': 'office-dns',
          'body': {'type': 'udp', 'server': '10.0.0.1'},
          'description': 'Office',
        },
        {
          'enabled': true,
          'kind': 'template',
          'tag': 'google_udp',
          'varValues': {'dns_ip': '8.8.4.4'},
        },
      ], dnsRules: [
        {
          'kind': 'inline',
          'name': 'corp',
          'rule': {'server': 'office-dns'},
          'enabled': false,
        },
        {'kind': 'preset', 'presetId': 'block-ads', 'enabled': true},
        {
          'kind': 'srs',
          'name': 'geo',
          'id': 'ds-geo',
          'srsUrl': 'https://example-2.com/geo.srs',
          'server': 'office-dns',
        },
      ]));
      expect([for (final e in c.rawDnsServers) _server(e, c.format).item], const [
        DnsServerInline(
          enabled: true,
          tag: 'office-dns',
          body: {'type': 'udp', 'server': '10.0.0.1'},
          description: 'Office',
        ),
        DnsServerTemplate(
            enabled: true, tag: 'google_udp', varValues: {'dns_ip': '8.8.4.4'}),
      ]);
      expect(_dnsRule(c.rawDnsRules[0], c.format).item,
          const DnsRuleInline(name: 'corp', rule: {'server': 'office-dns'}, enabled: false));
      expect(_dnsRule(c.rawDnsRules[1], c.format).item,
          const DnsRulePreset(presetId: 'block-ads', enabled: true));
      final srs = _dnsRule(c.rawDnsRules[2], c.format).item! as DnsRuleSrs;
      expect(srs.srsUrl, 'https://example-2.com/geo.srs');
      expect(srs.server, 'office-dns');
      expect(srs.id, isNot('ds-geo'));
    });
  });

  group('читатель выбирает format конверта', () {
    test('запись 1.0 в файле format 1 не читается', () {
      expect(
          _server({
            'kind': 'user',
            'tag': 'x',
            'enabled': true,
            'body': {'type': 'udp', 'server': '1.1.1.1'},
          }, kRulesFormatLegacy)
              .skipReason,
          ImportDnsSkipReason.unsupportedEntry);
      expect(
          _dnsRule({'kind': 'preset', 'ref': 'block-ads', 'enabled': true},
                  kRulesFormatLegacy)
              .skipReason,
          ImportDnsSkipReason.unsupportedEntry);
    });

    test('форма 2.23.2 в файле format 2 не читается', () {
      expect(
          _server({
            'enabled': true,
            'kind': 'inline',
            'tag': 'x',
            'body': {'type': 'udp', 'server': '1.1.1.1'},
          }, kRulesExportFormatVersion)
              .skipReason,
          ImportDnsSkipReason.unsupportedEntry);
      expect(
          _dnsRule({'kind': 'inline', 'name': 'x', 'rule': {'server': 's'}},
                  kRulesExportFormatVersion)
              .skipReason,
          ImportDnsSkipReason.unsupportedEntry);
      // Элемент правила формы 2.23.2: матчеры и цель — ключи верхнего
      // уровня, у записи 1.0 они в `body`, и кодек их не видит.
      final old = _rule({
        'kind': 'inline',
        'name': 'Old',
        'domains': ['a.example'],
        'outbound': 'vpn-1',
      }, kRulesExportFormatVersion)
          .rule! as CustomRuleInline;
      expect(old.domains, isEmpty);
      expect(old.outbound, isNot('vpn-1'));
    });
  });
}
