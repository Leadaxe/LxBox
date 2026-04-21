import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/selectable_to_custom.dart';

WizardTemplate _templateWith(Map<String, dynamic> config) => WizardTemplate(
      parserConfig: ParserConfigBlock(),
      presetGroups: const [],
      vars: const <WizardVar>[],
      varSections: const <VarSection>[],
      config: config,
      selectableRules: const [],
      dnsOptions: const {},
      pingOptions: const {},
      speedTestOptions: const {},
    );

void main() {
  final blankTemplate = _templateWith(const {});

  group('selectableRuleToCustom (bundle-only, spec §033)', () {
    test('любой пресет с preset_id → CustomRule(kind: preset) с тонкой ссылкой',
        () {
      final sr = SelectableRule(
        label: 'Russian domains direct',
        presetId: 'ru-direct',
        vars: [
          WizardVar(name: 'outbound', type: 'outbound', defaultValue: 'direct-out'),
        ],
        rule: const {'rule_set': 'ru-domains', 'outbound': '@out'},
      );
      final cr = selectableRuleToCustom(sr, blankTemplate);
      expect(cr, isNotNull);
      expect(cr, isA<CustomRulePreset>());
      expect(cr!.presetId, 'ru-direct');
      expect(cr.name, 'Russian domains direct');
      expect(cr.varsValues, isEmpty);
    });

    test('пресет без vars (только rule + rule_set, как Block Ads) — всё равно '
        'CustomRulePreset', () {
      final sr = SelectableRule(
        label: 'Block Ads',
        presetId: 'block-ads',
        ruleSets: [
          {'tag': 'ads', 'type': 'remote', 'url': 'https://ex.com/ads.srs'},
        ],
        rule: const {'rule_set': 'ads', 'action': 'reject'},
      );
      final cr = selectableRuleToCustom(sr, blankTemplate);
      expect(cr, isA<CustomRulePreset>());
      expect(cr!.presetId, 'block-ads');
    });

    test('overrideOutbound → varsValues["outbound"]', () {
      final sr = SelectableRule(
        label: 'Russian direct',
        presetId: 'ru-direct',
        rule: const {'rule_set': 'x', 'outbound': '@outbound'},
      );
      final cr = selectableRuleToCustom(sr, blankTemplate,
          overrideOutbound: 'vpn-1');
      expect(cr, isA<CustomRulePreset>());
      expect(cr!.varsValues['outbound'], 'vpn-1');
    });

    test('пресет без preset_id (ошибка шаблона) → null', () {
      final sr = SelectableRule(
        label: 'Malformed',
        rule: const {'outbound': 'direct-out'},
      );
      final cr = selectableRuleToCustom(sr, blankTemplate);
      expect(cr, isNull);
    });

    test('label пустой → имя берётся из preset_id', () {
      final sr = SelectableRule(label: '', presetId: 'my-preset');
      final cr = selectableRuleToCustom(sr, blankTemplate);
      expect(cr!.name, 'my-preset');
    });
  });
}
