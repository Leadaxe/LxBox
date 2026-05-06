import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';

void main() {
  group('applyPresetBundles (spec §033, sealed sig)', () {
    test('активный preset регистрирует rule_set + routing rule в registry, '
        'возвращает extra DNS данные (route+dns enabled)', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'Russian domains direct',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out', 'dns_server': 'yandex_doh'},
      );
      final reg = RuleSetRegistry();

      // §033: DNS-aspect независим. Включаем для этого теста.
      final result = applyPresetBundles(
        reg,
        [rule],
        [preset],
        isPresetDnsEnabled: const {'ru-direct': true},
      );

      expect(result.warnings, isEmpty);
      expect(reg.getRuleSets().length, 1);
      expect(reg.getRuleSets().first['tag'], 'ru-domains');
      expect(reg.getRules().length, 1);
      expect(reg.getRules().first,
          {'rule_set': 'ru-domains', 'outbound': 'direct-out'});
      expect(result.extraDnsServers.length, 1);
      expect(result.extraDnsServers.first['tag'], 'yandex_doh');
      expect(result.extraDnsRules.length, 1);
      expect(result.extraDnsRules.first,
          {'rule_set': 'ru-domains', 'server': 'yandex_doh'});

      // §033: dnsRulesByPresetId — авторитативный источник для applyCustomDns
      // (по immutable presetId). labelByPresetId — для UI рендера.
      expect(result.dnsRulesByPresetId, hasLength(1));
      expect(result.dnsRulesByPresetId['ru-direct'],
          {'rule_set': 'ru-domains', 'server': 'yandex_doh'});
      expect(result.labelByPresetId['ru-direct'], 'Russian domains direct');
    });

    test('§033 independent enable: route active, dns disabled → '
        'route emit но без DNS fragments', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'Russian domains direct',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out', 'dns_server': 'yandex_doh'},
      );
      final reg = RuleSetRegistry();

      final result = applyPresetBundles(
        reg,
        [rule],
        [preset],
        // dns не enabled (default false)
      );

      // Route side активен — rule_set и routing rule зарегистрированы
      expect(reg.getRuleSets().length, 1);
      expect(reg.getRules().length, 1);

      // DNS side НЕ активен — dns_rule и dns_servers пропущены
      expect(result.dnsRulesByPresetId, isEmpty);
      expect(result.extraDnsServers, isEmpty);
    });

    test('§033 independent enable: dns active, route disabled → '
        'DNS fragments но без routing rule', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'ru-direct',
        enabled: false, // route side выключен
        varsValues: {'outbound': 'direct-out', 'dns_server': 'yandex_doh'},
      );
      final reg = RuleSetRegistry();

      final result = applyPresetBundles(
        reg,
        [rule],
        [preset],
        isPresetDnsEnabled: const {'ru-direct': true},
      );

      // Route side выключен — routing rule не эмитится
      expect(reg.getRules(), isEmpty);
      // Но rule_set всё равно регистрируется (на него ссылается DNS rule)
      expect(reg.getRuleSets().length, 1);
      expect(reg.getRuleSets().first['tag'], 'ru-domains');

      // DNS side активен — dns_rule и dns_servers эмитятся
      expect(result.dnsRulesByPresetId, hasLength(1));
      expect(result.dnsRulesByPresetId['ru-direct'],
          {'rule_set': 'ru-domains', 'server': 'yandex_doh'});
      expect(result.extraDnsServers.length, 1);
      expect(result.extraDnsServers.first['tag'], 'yandex_doh');
    });

    test('broken preset (presetId не найден) → warning + skip', () {
      final rule = CustomRulePreset(
        name: 'Ghost',
        presetId: 'missing',
      );
      final reg = RuleSetRegistry();

      final result = applyPresetBundles(reg, [rule], const []);

      expect(result.warnings.length, 1);
      expect(result.warnings.first, contains('missing'));
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), isEmpty);
      expect(result.extraDnsServers, isEmpty);
    });

    test('disabled preset-правило — пропускается полностью', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'ru-direct',
        enabled: false,
        varsValues: {'outbound': 'direct-out'},
      );
      final reg = RuleSetRegistry();

      final result = applyPresetBundles(reg, [rule], [preset]);

      expect(result.warnings, isEmpty);
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), isEmpty);
    });

    test('inline правила пропускаются (обрабатывает applyCustomRules)', () {
      final preset = _ruDirect();
      final rule = CustomRuleInline(
        name: 'Firefox .ru',
        domainSuffixes: const ['ru'],
      );
      final reg = RuleSetRegistry();

      final result = applyPresetBundles(reg, [rule], [preset]);

      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), isEmpty);
      expect(result.extraDnsServers, isEmpty);
    });

    test('два preset-правила с одним presetId и одинаковыми vars — '
        'identical-skip rule_set', () {
      final preset = _ruDirect();
      final ruleA = CustomRulePreset(
        name: 'A',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out'},
      );
      final ruleB = CustomRulePreset(
        name: 'B',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out'},
      );
      final reg = RuleSetRegistry();

      final result = applyPresetBundles(reg, [ruleA, ruleB], [preset]);

      expect(result.warnings, isEmpty,
          reason: 'identical content — silent skip');
      expect(reg.getRuleSets().length, 1,
          reason: 'один rule_set "ru-domains" на оба правила');
      expect(reg.getRules().length, 2);
    });

    test('rule_set tag сохраняется без auto-suffix (routing rule ссылается '
        'на литерал)', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out'},
      );
      final reg = RuleSetRegistry();

      applyPresetBundles(reg, [rule], [preset]);

      expect(reg.getRuleSets().first['tag'], 'ru-domains');
      expect(reg.getRules().first['rule_set'], 'ru-domains');
    });
  });
}

SelectableRule _ruDirect() => SelectableRule(
      label: 'Russian domains direct',
      defaultEnabled: true,
      presetId: 'ru-direct',
      vars: [
        WizardVar(
          name: 'outbound',
          type: 'outbound',
          defaultValue: 'direct-out',
        ),
        WizardVar(
          name: 'dns_server',
          type: 'dns_servers',
          defaultValue: 'yandex_doh',
          required: false,
        ),
      ],
      ruleSets: [
        {
          'tag': 'ru-domains',
          'type': 'inline',
          'format': 'domain_suffix',
          'rules': [
            {
              'domain_suffix': ['ru']
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
      ],
    );
