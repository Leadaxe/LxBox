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

  group('selectableRuleToCustom', () {
    test('remote rule_set → srs CustomRule с URL из первого set', () {
      final sr = SelectableRule(
        label: 'Block Ads',
        description: 'reject ads',
        ruleSets: [
          {'tag': 'ads', 'type': 'remote', 'url': 'https://ex.com/a.srs'},
        ],
        rule: {'rule_set': 'ads', 'action': 'reject'},
      );
      final cr = selectableRuleToCustom(sr, blankTemplate);
      expect(cr, isNotNull);
      expect(cr!.name, 'Block Ads');
      expect(cr.kind, CustomRuleKind.srs);
      expect(cr.srsUrl, 'https://ex.com/a.srs');
      expect(cr.target, kRejectTarget);
    });

    test('rule.rule_set ссылка на template inline rule_set → раскрываем match', () {
      final tmpl = _templateWith({
        'route': {
          'rule_set': [
            {
              'tag': 'ru-domains',
              'type': 'inline',
              'rules': [
                {'domain_suffix': ['ru', 'xn--p1ai', 'su']},
              ],
            },
          ],
        },
      });
      final sr = SelectableRule(
        label: 'Russian domains direct',
        rule: {'rule_set': 'ru-domains', 'outbound': 'direct-out'},
      );
      final cr = selectableRuleToCustom(sr, tmpl);
      expect(cr, isNotNull);
      expect(cr!.kind, CustomRuleKind.inline);
      expect(cr.domainSuffixes, ['ru', 'xn--p1ai', 'su']);
      expect(cr.target, 'direct-out');
    });

    test('inline rule с protocol → CustomRule с protocols', () {
      final sr = SelectableRule(
        label: 'BitTorrent direct',
        rule: {
          'protocol': ['bittorrent'],
          'outbound': 'direct-out',
        },
      );
      final cr = selectableRuleToCustom(sr, blankTemplate);
      expect(cr, isNotNull);
      expect(cr!.protocols, ['bittorrent']);
      expect(cr.target, 'direct-out');
    });

    test('overrideOutbound меняет target', () {
      final sr = SelectableRule(
        label: 'Foo',
        ruleSets: [
          {'tag': 'foo', 'type': 'remote', 'url': 'https://ex.com/foo.srs'},
        ],
        rule: {'rule_set': 'foo', 'outbound': 'direct-out'},
      );
      final cr = selectableRuleToCustom(sr, blankTemplate,
          overrideOutbound: 'vpn-1');
      expect(cr!.target, 'vpn-1');
    });

    test('ссылка на несуществующий inline rule_set → null', () {
      final sr = SelectableRule(
        label: 'Ghost',
        rule: {'rule_set': 'missing', 'outbound': 'direct-out'},
      );
      final cr = selectableRuleToCustom(sr, blankTemplate);
      expect(cr, isNull);
    });

    test('пустой rule → null', () {
      final sr = SelectableRule(label: 'Empty');
      final cr = selectableRuleToCustom(sr, blankTemplate);
      expect(cr, isNull);
    });
  });
}
