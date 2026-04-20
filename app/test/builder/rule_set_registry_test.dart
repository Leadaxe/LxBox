import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/builder/rule_set_registry.dart';

void main() {
  group('RuleSetRegistry', () {
    test('empty registry → empty getters', () {
      final r = RuleSetRegistry();
      expect(r.getRuleSets(), isEmpty);
      expect(r.getRules(), isEmpty);
    });

    test('addRuleSet returns requested tag when free', () {
      final r = RuleSetRegistry();
      final tag = r.addRuleSet({'tag': 'my-rule', 'type': 'inline'});
      expect(tag, 'my-rule');
      expect(r.getRuleSets(), hasLength(1));
      expect(r.getRuleSets().first['tag'], 'my-rule');
    });

    test('addRuleSet auto-suffixes on collision: (2), (3), …', () {
      final r = RuleSetRegistry();
      final t1 = r.addRuleSet({'tag': 'Russian', 'type': 'inline'});
      final t2 = r.addRuleSet({'tag': 'Russian', 'type': 'inline'});
      final t3 = r.addRuleSet({'tag': 'Russian', 'type': 'inline'});
      expect(t1, 'Russian');
      expect(t2, 'Russian (2)');
      expect(t3, 'Russian (3)');
      expect(r.getRuleSets().map((e) => e['tag']).toList(),
          ['Russian', 'Russian (2)', 'Russian (3)']);
    });

    test('addRuleSet copies entry — no mutation of caller map', () {
      final r = RuleSetRegistry();
      r.addRuleSet({'tag': 'base', 'type': 'inline'}); // occupies 'base'
      final callerMap = {'tag': 'base', 'type': 'inline', 'rules': []};
      final tag = r.addRuleSet(callerMap);
      expect(tag, 'base (2)');
      expect(callerMap['tag'], 'base',
          reason: 'caller map should remain unchanged');
    });

    test('empty/whitespace tag → "unnamed" + collisions', () {
      final r = RuleSetRegistry();
      expect(r.addRuleSet({'tag': '', 'type': 'inline'}), 'unnamed');
      expect(r.addRuleSet({'tag': '   ', 'type': 'inline'}), 'unnamed (2)');
      expect(r.addRuleSet({'type': 'inline'}), 'unnamed (3)');
    });

    test('addRule preserves order', () {
      final r = RuleSetRegistry();
      r.addRule({'action': 'resolve'});
      r.addRule({'action': 'sniff'});
      r.addRule({'rule_set': 'ads', 'action': 'reject'});
      final rules = r.getRules();
      expect(rules, hasLength(3));
      expect(rules[0]['action'], 'resolve');
      expect(rules[2]['rule_set'], 'ads');
    });

    test('addRule copies caller map', () {
      final r = RuleSetRegistry();
      final caller = {'action': 'resolve', 'inbound': 'tun'};
      r.addRule(caller);
      caller['inbound'] = 'mutated';
      expect(r.getRules().first['inbound'], 'tun',
          reason: 'registry should snapshot rule on add');
    });

    test('initial rule_sets are admitted and their tags reserved', () {
      final r = RuleSetRegistry(
        initialRuleSets: [
          {'tag': 'ads-all', 'type': 'remote'},
          {'tag': 'ru-domains', 'type': 'inline'},
        ],
      );
      expect(r.getRuleSets().map((e) => e['tag']).toList(),
          ['ads-all', 'ru-domains']);
      final tag = r.addRuleSet({'tag': 'ads-all', 'type': 'inline'});
      expect(tag, 'ads-all (2)');
    });

    test('initial rule_sets with dup tags get auto-suffixed too', () {
      final r = RuleSetRegistry(
        initialRuleSets: [
          {'tag': 'dup', 'type': 'inline'},
          {'tag': 'dup', 'type': 'remote'},
        ],
      );
      expect(r.getRuleSets().map((e) => e['tag']).toList(), ['dup', 'dup (2)']);
    });

    test('initial rules passed through unchanged (order preserved)', () {
      final r = RuleSetRegistry(
        initialRules: [
          {'action': 'resolve', 'inbound': 'tun-in'},
          {'action': 'sniff', 'inbound': 'tun-in'},
          {'protocol': 'dns', 'action': 'hijack-dns'},
        ],
      );
      final rules = r.getRules();
      expect(rules, hasLength(3));
      expect(rules[0]['action'], 'resolve');
      expect(rules[2]['protocol'], 'dns');
    });

    test('getters return unmodifiable lists', () {
      final r = RuleSetRegistry();
      r.addRuleSet({'tag': 'x', 'type': 'inline'});
      expect(() => r.getRuleSets().add({'tag': 'y'}), throwsUnsupportedError);
      expect(() => r.getRules().add({'action': 'z'}), throwsUnsupportedError);
    });
  });
}
