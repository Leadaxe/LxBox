import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/rule_name_resolver.dart';

/// §279 Phase 2 (§3.5.4) — RuleNameResolver.relocalize: пере-дерайв
/// preset-label-частей зеркал из custom_rules + свежелокализованного шаблона
/// и сброс мемоизации, БЕЗ касания конфига (условия правил не меняются).
void main() {
  WizardTemplate template(String label) => WizardTemplate.fromJson({
        'selectable_rules': [
          {
            'preset_id': 'block-ads',
            'ui': {'label': label},
            'rule': {'rule_set': 'geosite-ads', 'action': 'reject'},
            'rule_set': [
              {
                'type': 'remote',
                'tag': 'geosite-ads',
                'url': 'https://example.com/ads.srs',
              },
            ],
          },
        ],
      });

  setUp(() => RuleNameResolver.I.clear());
  tearDown(() => RuleNameResolver.I.clear());

  const kernelRule = 'rule_set=geosite-ads => route(reject)';

  test('preset-правило резолвится в live-label по rule_set-тегу шаблона', () {
    RuleNameResolver.I.setRules(
      [CustomRulePreset(name: 'Block Ads', presetId: 'block-ads')],
      template: template('Block Ads'),
    );
    expect(RuleNameResolver.I.resolve(kernelRule), 'Block Ads');
  });

  test('relocalize: смена label в шаблоне отражается в выводе резолвера', () {
    RuleNameResolver.I.setRules(
      [CustomRulePreset(name: 'Block Ads', presetId: 'block-ads')],
      template: template('Block Ads'),
    );
    // Прогреваем мемо-кэш старым значением.
    expect(RuleNameResolver.I.resolve(kernelRule), 'Block Ads');

    RuleNameResolver.I.relocalize(template('Блок рекламы'));
    expect(RuleNameResolver.I.resolve(kernelRule), 'Блок рекламы',
        reason: 'мемоизация сброшена, титул пере-дерайвлен из нового шаблона');
  });

  test('без шаблона fallback остаётся прежним — сырой rule_set-тег', () {
    RuleNameResolver.I.setRules(
      [CustomRulePreset(name: 'Block Ads', presetId: 'block-ads')],
    );
    expect(RuleNameResolver.I.resolve(kernelRule), 'geosite-ads');
  });

  test('relocalize не трогает условия inline-правил (только титулы)', () {
    RuleNameResolver.I.setRules(
      [
        CustomRuleInline(name: 'Home', domainSuffixes: ['a.com']),
        CustomRulePreset(name: 'Block Ads', presetId: 'block-ads'),
      ],
      template: template('Block Ads'),
    );
    expect(RuleNameResolver.I.resolve('domain_suffix=a.com'), 'Home');
    RuleNameResolver.I.relocalize(template('Блок рекламы'));
    expect(RuleNameResolver.I.resolve('domain_suffix=a.com'), 'Home');
    expect(RuleNameResolver.I.resolve(kernelRule), 'Блок рекламы');
  });
}
