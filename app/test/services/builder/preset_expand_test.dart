import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/preset_expand.dart';

void main() {
  group('expandPreset (spec §033)', () {
    test('все vars заданы → полные fragments', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'Russian domains direct',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'vpn-1', 'dns_server': 'yandex_doh'},
      );

      final f = expandPreset(rule, preset);

      expect(f.warnings, isEmpty);
      expect(f.ruleSets.length, 1);
      expect(f.ruleSets.first['tag'], 'ru-domains');
      expect(f.dnsRule, {'rule_set': 'ru-domains', 'server': 'yandex_doh'});
      expect(f.routingRule,
          {'rule_set': 'ru-domains', 'outbound': 'vpn-1'});
      expect(f.dnsServers.length, 1);
      expect(f.dnsServers.first['tag'], 'yandex_doh');
      expect(f.dnsServers.first['detour'], 'vpn-1');
    });

    test('optional var: default_value применяется когда varsValues не содержит '
        'ключ (юзер не трогал)', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'Russian domains direct',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out'}, // dns_server не трогал
      );

      final f = expandPreset(rule, preset);

      expect(f.warnings, isEmpty);
      expect(f.dnsRule, {'rule_set': 'ru-domains', 'server': 'yandex_doh'},
          reason: 'default_value из шаблона применяется');
      expect(f.dnsServers.length, 1);
      expect(f.dnsServers.first['tag'], 'yandex_doh');
    });

    test('optional var: явная пустая строка → фрагменты с @var dropped', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'ru-direct',
        // '' = explicit "— (default DNS)" из UI dropdown'а
        varsValues: {'outbound': 'direct-out', 'dns_server': ''},
      );

      final f = expandPreset(rule, preset);

      expect(f.warnings, isEmpty);
      expect(f.routingRule!['outbound'], 'direct-out');
      expect(f.dnsRule, isNull);
      expect(f.dnsServers, isEmpty);
    });

    test('@outbound == direct-out → detour удаляется из dns_servers', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'Russian domains direct',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out', 'dns_server': 'yandex_doh'},
      );

      final f = expandPreset(rule, preset);

      expect(f.dnsServers.length, 1);
      expect(f.dnsServers.first.containsKey('detour'), isFalse);
      expect(f.routingRule!['outbound'], 'direct-out');
    });

    test('required var без explicit + defaultValue → substituted by default', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'Russian domains direct',
        presetId: 'ru-direct',
        varsValues: {}, // out required, default_value='direct-out' → direct
      );

      final f = expandPreset(rule, preset);

      expect(f.warnings, isEmpty);
      expect(f.routingRule!['outbound'], 'direct-out');
    });

    test('required var + no value + empty default → empty fragments + warn', () {
      final preset = SelectableRule(
        label: 'Broken',
        presetId: 'broken',
        vars: [
          WizardVar(
            name: 'outbound',
            type: 'outbound',
            defaultValue: '', // no default, but required
          ),
        ],
        ruleSets: const [],
        rule: const {'outbound': '@outbound'},
      );
      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'broken',
      );

      final f = expandPreset(rule, preset);

      expect(f.isEmpty, isTrue);
      expect(f.warnings.length, 1);
      expect(f.warnings.first, contains('required var "outbound"'));
    });

    test('фильтр dns_servers — только выбранный tag', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out', 'dns_server': 'yandex_safe'},
      );

      final f = expandPreset(rule, preset);

      expect(f.dnsServers.length, 1);
      expect(f.dnsServers.first['tag'], 'yandex_safe');
    });

    test('remote rule_set + cached path → заменяется на type: local, path',
        () {
      final preset = SelectableRule(
        label: 'Block Ads',
        presetId: 'block-ads',
        ruleSets: [
          {
            'tag': 'ads-all',
            'type': 'remote',
            'format': 'binary',
            'url': 'https://ex.com/ads.srs',
          }
        ],
        rule: const {'rule_set': 'ads-all', 'action': 'reject'},
      );
      final rule = CustomRulePreset(name: 'Block Ads', presetId: 'block-ads');

      final f = expandPreset(rule, preset,
          srsPaths: {'ads-all': '/cache/preset__block-ads__ads-all.srs'});

      expect(f.warnings, isEmpty);
      expect(f.ruleSets.length, 1);
      final rs = f.ruleSets.first;
      expect(rs['type'], 'local', reason: 'remote → local (spec §011)');
      expect(rs['path'], '/cache/preset__block-ads__ads-all.srs');
      expect(rs.containsKey('url'), isFalse);
      expect(rs['tag'], 'ads-all');
    });

    test('remote rule_set + НЕТ cached path → rule_set skipped + warning + '
        'routing_rule тоже dropped (dangling-ref защита)', () {
      final preset = SelectableRule(
        label: 'Block Ads',
        presetId: 'block-ads',
        ruleSets: [
          {'tag': 'ads-all', 'type': 'remote', 'url': 'https://ex.com/ads.srs'}
        ],
        rule: const {'rule_set': 'ads-all', 'action': 'reject'},
      );
      final rule = CustomRulePreset(name: 'Block Ads', presetId: 'block-ads');

      final f = expandPreset(rule, preset); // srsPaths: {}

      expect(f.ruleSets, isEmpty,
          reason: 'без кэша remote rule_set не попадает в конфиг');
      expect(f.routingRule, isNull,
          reason: 'rule без своего rule_set → drop, иначе sing-box падает '
              'с "rule-set not found"');
      expect(f.warnings.length, 2,
          reason: 'один warning про rule_set skip, второй про routing_rule skip');
      expect(f.warnings.any((w) => w.contains('no cached file')), isTrue);
      expect(f.warnings.any((w) => w.contains('missing rule_set')), isTrue);
    });

    test('routing rule без outbound/action после substitute → dropped', () {
      final preset = SelectableRule(
        label: 'Weird',
        presetId: 'weird',
        vars: [
          WizardVar(
            name: 'target',
            type: 'outbound',
            defaultValue: '',
            required: false,
          ),
        ],
        rule: const {'rule_set': 'x', 'outbound': '@target'},
      );
      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'weird',
      );

      final f = expandPreset(rule, preset);

      expect(f.routingRule, isNull);
    });
  });

  group('mergeFragments (spec §033)', () {
    test('identical skip по tag', () {
      final f1 = PresetFragments(
        dnsServers: [
          {'tag': 'yandex_doh', 'type': 'https', 'server': 'a'}
        ],
        ruleSets: [
          {
            'tag': 'ru-domains',
            'type': 'inline',
            'rules': [
              {
                'domain_suffix': ['ru']
              }
            ]
          }
        ],
      );
      final f2 = PresetFragments(
        dnsServers: [
          {'tag': 'yandex_doh', 'type': 'https', 'server': 'a'}
        ],
        ruleSets: [
          {
            'tag': 'ru-domains',
            'type': 'inline',
            'rules': [
              {
                'domain_suffix': ['ru']
              }
            ]
          }
        ],
      );

      final m = mergeFragments([f1, f2]);
      expect(m.dnsServers.length, 1);
      expect(m.ruleSets.length, 1);
      expect(m.warnings, isEmpty);
    });

    test('real conflict — first-wins + warning', () {
      final f1 = PresetFragments(dnsServers: [
        {'tag': 'yandex_doh', 'type': 'https', 'server': 'a'}
      ]);
      final f2 = PresetFragments(dnsServers: [
        {'tag': 'yandex_doh', 'type': 'https', 'server': 'b'}
      ]);

      final m = mergeFragments([f1, f2]);
      expect(m.dnsServers.length, 1);
      expect(m.dnsServers.first['server'], 'a');
      expect(m.warnings.length, 1);
      expect(m.warnings.first, contains('yandex_doh'));
    });

    test('dns_rules и routing_rules append без dedup', () {
      final f1 = PresetFragments(
        dnsRule: {'rule_set': 'ru-domains', 'server': 'a'},
        routingRule: {'rule_set': 'ru-domains', 'outbound': 'direct-out'},
      );
      final f2 = PresetFragments(
        dnsRule: {'rule_set': 'x', 'server': 'b'},
        routingRule: {'rule_set': 'x', 'outbound': 'vpn-1'},
      );

      final m = mergeFragments([f1, f2]);
      expect(m.dnsRules.length, 2);
      expect(m.routingRules.length, 2);
    });

    test('порядок детерминирован — bundle A затем B', () {
      final a = PresetFragments(dnsServers: [
        {'tag': 'a', 'type': 'udp'}
      ]);
      final b = PresetFragments(dnsServers: [
        {'tag': 'b', 'type': 'udp'}
      ]);

      final ab = mergeFragments([a, b]);
      expect(ab.dnsServers.map((s) => s['tag']).toList(), ['a', 'b']);

      final ba = mergeFragments([b, a]);
      expect(ba.dnsServers.map((s) => s['tag']).toList(), ['b', 'a']);
    });
  });
}

/// Фабрика — сокращённая реплика `Russian domains direct` из шаблона.
SelectableRule _ruDirect() => SelectableRule(
      label: 'Russian domains direct',
      description: 'Route Russian & Cyrillic TLDs directly.',
      defaultEnabled: true,
      presetId: 'ru-direct',
      vars: [
        WizardVar(
          name: 'outbound',
          type: 'outbound',
          defaultValue: 'direct-out',
          title: 'Outbound',
        ),
        WizardVar(
          name: 'dns_server',
          type: 'dns_servers',
          defaultValue: 'yandex_doh',
          required: false,
          title: 'DNS server',
        ),
      ],
      ruleSets: [
        {
          'tag': 'ru-domains',
          'type': 'inline',
          'format': 'domain_suffix',
          'rules': [
            {
              'domain_suffix': ['ru', 'xn--p1ai']
            }
          ]
        }
      ],
      dnsRule: const {'rule_set': 'ru-domains', 'server': '@dns_server'},
      rule: const {'rule_set': 'ru-domains', 'outbound': '@outbound'},
      dnsServers: [
        {
          'type': 'https',
          'tag': 'yandex_doh',
          'server': '77.88.8.88',
          'detour': '@outbound',
          'description': 'Yandex DoH',
        },
        {
          'type': 'udp',
          'tag': 'yandex_safe',
          'server': '77.88.8.88',
          'detour': '@outbound',
          'description': 'Yandex Safe',
        },
      ],
    );
