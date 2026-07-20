import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/screens/routing_screen/routing_screen_helpers.dart';
import 'package:lxbox/services/rule_display_names.dart';

/// §279 Phase 2 (§3.5.1) — live display-имена preset-правил: label из
/// локализованного шаблона, порядковая дизамбигуация копий, дедуп новых
/// имён по видимым (display-резолвнутым) именам.
void main() {
  WizardTemplate template({String label = 'Block Ads'}) =>
      WizardTemplate.fromJson({
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

  CustomRulePreset presetRule({String name = 'Block Ads'}) =>
      CustomRulePreset(name: name, presetId: 'block-ads');

  group('ruleDisplayName', () {
    test('preset: live-label из шаблона (снапшот name игнорируется)', () {
      final r = presetRule(name: 'Stale Snapshot');
      expect(ruleDisplayName(r, [r], template()), 'Block Ads');
    });

    test('preset: fallback на name-снапшот без шаблона / без пресета', () {
      final r = presetRule(name: 'Snapshot');
      expect(ruleDisplayName(r, [r], null), 'Snapshot');
      final other = WizardTemplate.fromJson({'selectable_rules': []});
      expect(ruleDisplayName(r, [r], other), 'Snapshot');
    });

    test('копии одного пресета: первая без суффикса, N-я — " (N)"', () {
      final a = presetRule();
      final b = presetRule();
      final c = presetRule();
      final rules = <CustomRule>[a, b, c];
      final t = template();
      expect(ruleDisplayName(a, rules, t), 'Block Ads');
      expect(ruleDisplayName(b, rules, t), 'Block Ads (2)');
      expect(ruleDisplayName(c, rules, t), 'Block Ads (3)');
    });

    test('inline/srs: сохранённое имя как есть', () {
      final r = CustomRuleInline(name: 'My rule');
      expect(ruleDisplayName(r, [r], template()), 'My rule');
    });
  });

  group('ruleDisplayNames', () {
    test('позиционно выровнен, ordinal по порядку списка', () {
      final rules = <CustomRule>[
        CustomRuleInline(name: 'First'),
        presetRule(),
        presetRule(),
      ];
      expect(ruleDisplayNames(rules, template()),
          ['First', 'Block Ads', 'Block Ads (2)']);
    });
  });

  group('visibleRuleNames / uniqueCustomRuleName (display-дедуп)', () {
    test('новое inline-правило не может взять видимый label пресета', () {
      final rules = <CustomRule>[presetRule(name: 'Snapshot')];
      // Видимое имя — live-label 'Block Ads': запрошенное имя коллизит.
      expect(
        RoutingHelpers.uniqueCustomRuleName(
            'Block Ads', '', rules, template()),
        'Block Ads (2)',
      );
      // Снапшот тоже защищён (коллизия всплыла бы при смене локали назад).
      expect(
        RoutingHelpers.uniqueCustomRuleName('Snapshot', '', rules, template()),
        'Snapshot (2)',
      );
      // Свободное имя проходит как есть.
      expect(
        RoutingHelpers.uniqueCustomRuleName('Free', '', rules, template()),
        'Free',
      );
    });

    test('selfId исключает собственные имена при rename', () {
      final r = CustomRuleInline(name: 'Mine');
      expect(
        RoutingHelpers.uniqueCustomRuleName('Mine', r.id, [r], null),
        'Mine',
      );
    });

    test('без шаблона (холодный кэш) — сравнение по сохранённым именам', () {
      final rules = <CustomRule>[presetRule(name: 'Snapshot')];
      expect(
        RoutingHelpers.uniqueCustomRuleName('Snapshot', '', rules, null),
        'Snapshot (2)',
      );
      // Live-label неизвестен без шаблона — не участвует.
      expect(
        RoutingHelpers.uniqueCustomRuleName('Block Ads', '', rules, null),
        'Block Ads',
      );
    });
  });
}
