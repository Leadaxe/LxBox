import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/rule_record.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/screens/custom_rule_edit/cond_stack.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';

// §757 — единый класс правила с корнем-деревом: поля формы ↔ таблица
// условий, круг записи старой и новой формы, обходы дерева вместо плоских
// геттеров, сборка с рукописным тегом и резервом тегов пресетов.

CustomRuleTree _groups({List<String> refs = const []}) => CustomRuleTree(
      id: 'g1',
      name: 'Groups',
      root: RuleGroup(mode: RuleGroup.kAnd, children: [
        const RuleLeaf(conditions: {
          'package_name': ['a.app'],
        }),
        RuleGroup(mode: RuleGroup.kOr, invert: true, children: [
          RuleLeaf(refs: refs, conditions: const {
            'domain_suffix': ['example-1.com'],
          }),
          const RuleLeaf(conditions: {
            'process_name': ['app.exe'],
          }),
        ]),
      ]),
      outbound: 'vpn-1',
      dns: const RuleDns(enabled: true, serverTag: 'doh'),
    );

void main() {
  test('каждое поле формы — ключ таблицы условий', () {
    final table = ruleConditionTable;
    for (final k in kRuleFormFieldKeys) {
      expect(table.isConditionKey(k), isTrue, reason: k);
    }
  });

  group('запись', () {
    test('старая форма (refs на записи) → модель → новая форма → то же', () {
      final old = ruleFromRecord({
        'kind': 'srs',
        'id': 'r1',
        'name': 'Geo',
        'refs': ['https://x/a.srs'],
        'update_interval_hours': 24,
        'body': {
          'port': [443],
          'outbound': 'vpn-1',
        },
      }).value! as CustomRuleTree;
      expect(old.kind, CustomRuleKind.srs);
      expect(old.updateIntervalHours, 24);
      final rec = ruleToRecord(old);
      expect(rec.containsKey('refs'), isFalse);
      expect(rec['body'], {
        'refs': ['https://x/a.srs'],
        'port': [443],
        'outbound': 'vpn-1',
      });
      expect(ruleFromRecord(rec).value, old);
    });

    test('дерево с группами — типизированно, не verbatim', () {
      final r = _groups(refs: const ['https://x/b.json']);
      final rec = ruleToRecord(r);
      expect(rec['kind'], 'srs');
      final back = ruleFromRecord(rec, unknownAsVerbatim: true);
      expect(back.unknownKeys, isEmpty);
      expect(back.value, r);
    });

    test('verbatim не превращается в дерево', () {
      final read = ruleFromRecord({
        'kind': 'inline',
        'name': 'raw',
        'verbatim': true,
        'body': {
          'domain': ['a.com'],
          'outbound': 'x',
        },
      });
      expect(read.value, isA<CustomRuleJson>());
    });

    test('preset: update_interval_hours хранится и провозится (§180)', () {
      final r = ruleFromRecord({
        'kind': 'preset',
        'ref': 'block-ads',
        'update_interval_hours': 0,
      }).value! as CustomRulePreset;
      expect(r.updateIntervalHours, 0);
      expect(ruleToRecord(r)['update_interval_hours'], 0);
      final none = ruleFromRecord({'kind': 'preset', 'ref': 'x'}).value!
          as CustomRulePreset;
      expect(none.updateIntervalHours, isNull);
      expect(ruleToRecord(none).containsKey('update_interval_hours'), isFalse);
    });
  });

  group('обходы дерева', () {
    test('плоские геттеры у правила с группами пусты, обходы — по дереву', () {
      final r = _groups(refs: const ['https://x/b.srs']);
      expect(r.flatLeaf, isNull);
      expect(r.packages, isEmpty);
      expect(r.srsUrls, isEmpty);
      expect(r.allRefs, ['https://x/b.srs']);
      expect(r.cacheIds, hasLength(1));
      expect(r.conditionValues('package_name'), ['a.app']);
      expect(r.hasDomainMatch, isTrue);
      expect(r.resolveEligible, isTrue);
      expect(r.dnsLayerEligible, isTrue);
      expect(r.summary(), isNotEmpty);
      expect(() => r.copyWith(domains: ['x']), throwsStateError);
    });

    test('DNS-опция при пустом зеркале', () {
      final ipOnly = CustomRuleTree.flat(
        name: 'ip',
        ipCidrs: ['10.0.0.0/8'],
        dns: const RuleDns(forceIpv4: true),
      );
      expect(ipOnly.dnsLayerEligible, isFalse);
      expect(ipOnly.dnsOptionsWithoutEffect, isTrue);
      // §757 — особый случай ip_cidr + inbound снят.
      final withInbound = ipOnly.copyWith(inbounds: ['tun-in']);
      expect(withInbound.dnsLayerEligible, isTrue);
      expect(withInbound.dnsOptionsWithoutEffect, isFalse);
    });
  });

  group('форма', () {
    test('форма условий открывает дерево; JSON — только два способа one_of',
        () {
      CondStack? open(CustomRuleTree r) =>
          CondStack.fromNode(r.root, ruleConditionTable);
      expect(open(CustomRuleTree.flat(name: 'a', domains: ['a.com'])),
          isNotNull);
      expect(
          open(CustomRuleTree.flat(
              name: 'a', srsUrl: 'https://x/a.srs', domains: ['a.com'])),
          isNotNull);
      expect(
          open(CustomRuleTree.flat(name: 'a', extraConditions: const {
            'process_name': ['x'],
          })),
          isNotNull);
      expect(open(_groups()), isNotNull);
      expect(
          open(CustomRuleTree.flat(name: 'a', extraConditions: const {
            'process_name': ['x'],
            'process_path': ['/y'],
          })),
          isNull);
    });
  });

  group('сборка', () {
    test('рукописный тег вне route.rule_set — правило снимается целиком', () {
      final reg = RuleSetRegistry(initialRuleSets: [
        {'type': 'inline', 'tag': 'geo', 'rules': []},
      ]);
      final ok = CustomRuleTree.flat(
          name: 'Ok', ruleSet: const ['geo'], ports: ['443'], outbound: 'x');
      final bad = CustomRuleTree.flat(
        name: 'Bad',
        ruleSet: const ['missing'],
        domains: ['a.com'],
        outbound: 'x',
        dns: const RuleDns(enabled: true, serverTag: 'doh'),
      );
      final res = applyAllCustomRules(reg, [ok, bad], const []);
      final rules = reg.getRules();
      expect(rules, hasLength(1));
      expect(rules.single['rule_set'], 'geo');
      expect([for (final s in reg.getRuleSets()) s['tag']], ['geo']);
      expect(res.dnsMirrors.where((m) => m.ruleId == bad.id), isEmpty);
      expect(res.warnings.join('\n'), contains('"Bad"'));
      expect(res.warnings.join('\n'), contains('"missing"'));
    });

    test('теги наборов пресетов в правилах заняты, и у выключенного', () {
      final preset = SelectableRule(
        label: 'Ads',
        presetId: 'ads',
        ruleSets: const [
          {'type': 'inline', 'tag': 'Ads', 'rules': []},
        ],
      );
      final reg = RuleSetRegistry();
      applyAllCustomRules(
        reg,
        [
          CustomRulePreset(
              name: 'Ads', presetId: 'ads', enabled: false),
          CustomRuleTree.flat(name: 'Ads', domains: ['a.com'], outbound: 'x'),
        ],
        [preset],
      );
      expect([for (final s in reg.getRuleSets()) s['tag']], ['Ads (2)']);
    });
  });
}
