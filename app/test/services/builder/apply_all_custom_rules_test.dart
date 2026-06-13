import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';

/// §062 — `applyAllCustomRules` сохраняет storage order между preset/inline/srs.
///
/// Старый pipeline (`applyPresetBundles` → `applyCustomRules`) делал 2 прохода
/// и собирал [все preset] + [все inline/srs] в config.route.rules — что
/// ломало юзер-управляемый order. Эти тесты пинят правильное поведение.
void main() {
  group('applyAllCustomRules (§062 unified order)', () {
    test('storage [preset, inline, preset] → config rules в том же order',
        () {
      final preset = _ruDirect();
      final rules = <CustomRule>[
        CustomRulePreset(
          name: 'A',
          presetId: 'ru-direct',
          varsValues: {'outbound': 'direct-out'},
        ),
        CustomRuleInline(
          name: 'inline-mid',
          packages: ['com.example.app'],
          outbound: 'vpn-2',
        ),
        CustomRulePreset(
          name: 'B',
          // другой presetId чтобы не получить identical-skip
          presetId: 'ru-direct-2',
          varsValues: {'outbound': 'vpn-1'},
        ),
      ];
      final reg = RuleSetRegistry();

      applyAllCustomRules(reg, rules, [preset, _ruDirect2()]);

      final outbounds =
          reg.getRules().map((r) => r['outbound']).toList(growable: false);
      expect(outbounds, ['direct-out', 'vpn-2', 'vpn-1'],
          reason: 'order должен совпадать со storage: '
              'preset(direct), inline(vpn-2), preset(vpn-1)');
    });

    test('storage [inline, preset] → inline first', () {
      final preset = _ruDirect();
      final rules = <CustomRule>[
        CustomRuleInline(
          name: 'inline-first',
          domains: ['example.com'],
          outbound: 'vpn-3',
        ),
        CustomRulePreset(
          name: 'preset-after',
          presetId: 'ru-direct',
          varsValues: {'outbound': 'direct-out'},
        ),
      ];
      final reg = RuleSetRegistry();

      applyAllCustomRules(reg, rules, [preset]);

      final outbounds =
          reg.getRules().map((r) => r['outbound']).toList(growable: false);
      expect(outbounds, ['vpn-3', 'direct-out'],
          reason: 'inline должен быть первым (storage order)');
    });

    test('storage [preset, srs, preset] → srs middle', () {
      final preset = _ruDirect();
      final rules = <CustomRule>[
        CustomRulePreset(
          name: 'preset-A',
          presetId: 'ru-direct',
          varsValues: {'outbound': 'direct-out'},
        ),
        CustomRuleSrs(
          id: 'srs-id-1',
          name: 'srs-mid',
          srsUrl: 'https://example.com/rs.srs',
          outbound: 'vpn-2',
        ),
        CustomRulePreset(
          name: 'preset-B',
          presetId: 'ru-direct-2',
          varsValues: {'outbound': 'vpn-1'},
        ),
      ];
      final reg = RuleSetRegistry();

      applyAllCustomRules(
        reg,
        rules,
        [preset, _ruDirect2()],
        srsPaths: const {'srs-id-1': '/cache/srs-id-1'},
      );

      final outbounds =
          reg.getRules().map((r) => r['outbound']).toList(growable: false);
      expect(outbounds, ['direct-out', 'vpn-2', 'vpn-1']);
    });

    test('disabled inline между двумя preset не нарушает order остальных',
        () {
      final preset = _ruDirect();
      final rules = <CustomRule>[
        CustomRulePreset(
          name: 'A',
          presetId: 'ru-direct',
          varsValues: {'outbound': 'direct-out'},
        ),
        CustomRuleInline(
          name: 'disabled-inline',
          enabled: false,
          packages: ['com.skip.me'],
          outbound: 'vpn-skip',
        ),
        CustomRulePreset(
          name: 'B',
          presetId: 'ru-direct-2',
          varsValues: {'outbound': 'vpn-1'},
        ),
      ];
      final reg = RuleSetRegistry();

      applyAllCustomRules(reg, rules, [preset, _ruDirect2()]);

      final outbounds =
          reg.getRules().map((r) => r['outbound']).toList(growable: false);
      expect(outbounds, ['direct-out', 'vpn-1'],
          reason: 'disabled inline просто пропускается, '
              'enabled preset rules остаются в storage order');
    });

    test('два preset с одинаковым rule_set — identical-skip + cross-kind '
        'order сохраняется', () {
      final preset = _ruDirect();
      final rules = <CustomRule>[
        CustomRulePreset(
          name: 'A',
          presetId: 'ru-direct',
          varsValues: {'outbound': 'direct-out'},
        ),
        CustomRuleInline(
          name: 'inline-X',
          domains: ['example.com'],
          outbound: 'vpn-2',
        ),
        CustomRulePreset(
          name: 'B',
          presetId: 'ru-direct',
          varsValues: {'outbound': 'direct-out'},
        ),
      ];
      final reg = RuleSetRegistry();

      final result = applyAllCustomRules(reg, rules, [preset]);

      // Один уникальный rule_set от двух identical preset (identical-skip),
      // плюс один inline rule_set ("inline-X").
      expect(reg.getRuleSets().length, 2,
          reason: 'identical preset rule_set дедуплицирован, inline свой');
      // 3 routing rules в порядке storage: preset, inline, preset.
      final outbounds =
          reg.getRules().map((r) => r['outbound']).toList(growable: false);
      expect(outbounds, ['direct-out', 'vpn-2', 'direct-out']);
      expect(result.warnings, isEmpty,
          reason: 'identical-skip — silent (не warning)');
    });

    test('UnifiedApplyResult exposes DNS aspect от preset (как PresetApplyResult)',
        () {
      final preset = _ruDirect();
      final rules = <CustomRule>[
        CustomRulePreset(
          name: 'X',
          presetId: 'ru-direct',
          varsValues: {'outbound': 'direct-out', 'dns_server': 'yandex_doh'},
        ),
      ];
      final reg = RuleSetRegistry();

      final result = applyAllCustomRules(
        reg,
        rules,
        [preset],
        isPresetDnsEnabled: const {'ru-direct': true},
      );

      expect(result.extraDnsServers.length, 1);
      expect(result.extraDnsServers.first['tag'], 'yandex_doh');
      expect(result.dnsRulesByPresetId['ru-direct'],
          {'rule_set': 'ru-domains', 'server': 'yandex_doh'});
      expect(result.labelByPresetId['ru-direct'], 'Russian domains direct');
    });

    test('§121 — routing off (cr.enabled=false) подавляет DNS-аспект '
        'даже если isPresetDnsEnabled=true (routing = король)', () {
      final preset = _ruDirect();
      final rules = <CustomRule>[
        CustomRulePreset(
          name: 'X',
          enabled: false, // routing-тоггл выключен
          presetId: 'ru-direct',
          varsValues: {'outbound': 'direct-out', 'dns_server': 'yandex_doh'},
        ),
      ];
      final reg = RuleSetRegistry();

      final result = applyAllCustomRules(
        reg,
        rules,
        [preset],
        isPresetDnsEnabled: const {'ru-direct': true}, // DNS-аспект on, но gated
      );

      // §121: выключенный routing-тоггл = пресет мёртв целиком.
      expect(reg.getRules(), isEmpty, reason: 'нет routing-правила');
      expect(result.extraDnsServers, isEmpty,
          reason: 'серверы пресета не эмитятся');
      expect(result.dnsRulesByPresetId, isEmpty,
          reason: 'DNS-правило пресета не эмитится');
      expect(result.dnsMirrors, isEmpty, reason: 'mirror-lock не создаётся');
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
        }
      ],
    );

// Same shape but different presetId / rule_set tag — чтобы избежать
// identical-skip и иметь два разных preset для cross-kind order тестов.
SelectableRule _ruDirect2() => SelectableRule(
      label: 'Russian domains 2',
      defaultEnabled: true,
      presetId: 'ru-direct-2',
      vars: [
        WizardVar(
          name: 'outbound',
          type: 'outbound',
          defaultValue: 'vpn-1',
        ),
      ],
      ruleSets: [
        {
          'tag': 'ru-domains-2',
          'type': 'inline',
          'format': 'domain_suffix',
          'rules': [
            {
              'domain_suffix': ['su']
            }
          ]
        }
      ],
      rule: const {'rule_set': 'ru-domains-2', 'outbound': '@outbound'},
    );
