import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';

void main() {
  group('applyPresetBundles (spec §033, sealed sig)', () {
    test('активный preset регистрирует rule_set + routing rule в registry, '
        'возвращает extra DNS данные', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'Russian domains direct',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out', 'dns_server': 'yandex_doh'},
      );
      final reg = RuleSetRegistry();

      final result = applyPresetBundles(reg, [rule], [preset]);

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
