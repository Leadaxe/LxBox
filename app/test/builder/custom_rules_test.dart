import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';

void main() {
  group('applyCustomRules — inline', () {
    test('domain only → inline rule_set + outbound route', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRule(
          id: 'id-1',
          name: 'Pin Yandex',
          domains: ['ya.ru', 'yandex.ru'],
          target: 'direct-out',
        ),
      ]);
      final sets = reg.getRuleSets();
      expect(sets, hasLength(1));
      expect(sets.first['tag'], 'Pin Yandex');
      expect(sets.first['type'], 'inline');
      expect(sets.first['rules'], [
        {
          'domain': ['ya.ru', 'yandex.ru'],
        },
      ]);
      expect(reg.getRules(), [
        {'rule_set': 'Pin Yandex', 'outbound': 'direct-out'},
      ]);
    });

    test('domain_suffix-only rule emits domain_suffix field', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRule(
          name: 'RU',
          domainSuffixes: ['ru', 'xn--p1ai'],
          target: 'vpn-1',
        ),
      ]);
      expect(reg.getRuleSets().first['rules'].first,
          {'domain_suffix': ['ru', 'xn--p1ai']});
    });

    test('ip_cidr rule emits ip_cidr field', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRule(
          name: 'Home LAN',
          ipCidrs: ['10.0.0.0/8', '192.168.0.0/16'],
          target: 'direct-out',
        ),
      ]);
      expect(reg.getRuleSets().first['rules'].first,
          {'ip_cidr': ['10.0.0.0/8', '192.168.0.0/16']});
    });

    test('domain + suffix + ip в одном правиле → все в одном headless rule', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRule(
          name: 'Mixed',
          domains: ['foo.com'],
          domainSuffixes: ['bar.com'],
          ipCidrs: ['10.0.0.0/8'],
          target: 'direct-out',
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      expect(match, {
        'domain': ['foo.com'],
        'domain_suffix': ['bar.com'],
        'ip_cidr': ['10.0.0.0/8'],
      });
    });

    test('ports → int list, port_range → string list, в одном headless rule', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRule(
          name: 'HTTPS+range',
          domainSuffixes: ['example.com'],
          ports: ['443', '8443'],
          portRanges: ['8000:9000', ':3000'],
          target: 'vpn-1',
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      expect(match['port'], [443, 8443]);
      expect(match['port_range'], ['8000:9000', ':3000']);
    });

    test('packages → package_name в inline headless rule', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRule(
          name: 'Firefox RU',
          domainSuffixes: ['.ru'],
          packages: ['org.mozilla.firefox'],
          target: 'direct-out',
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      expect(match['package_name'], ['org.mozilla.firefox']);
      expect(match['domain_suffix'], ['.ru']);
      final rule = reg.getRules().first;
      expect(rule.containsKey('package_name'), isFalse);
    });

    test('packages-only rule → inline с одним package_name', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRule(
          name: 'Block bad app',
          packages: ['com.evil.app'],
          target: kRejectTarget,
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      expect(match, {'package_name': ['com.evil.app']});
      final rule = reg.getRules().first;
      expect(rule['action'], 'reject');
    });

    test('protocols идут на routing-rule level (headless не поддерживает)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRule(
          name: 'TLS quic',
          domainSuffixes: ['example.com'],
          protocols: ['tls', 'quic'],
          target: 'vpn-1',
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      expect(match.containsKey('protocol'), isFalse);
      final rule = reg.getRules().first;
      expect(rule['protocol'], ['tls', 'quic']);
      expect(rule['rule_set'], 'TLS quic');
      expect(rule['outbound'], 'vpn-1');
    });

    test('reject + protocol → action:reject со сохранением protocol', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRule(
          name: 'Block BT',
          domainSuffixes: ['.torrent'],
          protocols: ['bittorrent'],
          target: kRejectTarget,
        ),
      ]);
      final rule = reg.getRules().first;
      expect(rule['action'], 'reject');
      expect(rule.containsKey('outbound'), isFalse);
      expect(rule['protocol'], ['bittorrent']);
    });

    test('disabled → skipped', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRule(
          name: 'Never',
          enabled: false,
          domains: ['example.com'],
          target: 'direct-out',
        ),
      ]);
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), isEmpty);
    });

    test('no match fields → skipped', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRule(name: 'Empty inline', target: 'vpn-1'),
      ]);
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), isEmpty);
    });

    test('invalid port strings → отбрасываются на intPorts getter', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRule(
          name: 'Bad ports',
          ports: ['443', 'abc', '99999', '80'],
          target: 'vpn-1',
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      expect(match['port'], [443, 80]);
    });

    test('collision с существующим tag'
        ' → авто-суффикс через registry', () {
      final reg = RuleSetRegistry(
        initialRuleSets: [
          {'tag': 'Block', 'type': 'remote'},
        ],
      );
      applyCustomRules(reg, [
        CustomRule(
          name: 'Block',
          domainSuffixes: ['x.com'],
          target: kRejectTarget,
        ),
      ]);
      expect(reg.getRuleSets().map((s) => s['tag']).toList(),
          ['Block', 'Block (2)']);
      expect(reg.getRules().first['rule_set'], 'Block (2)');
    });
  });

  group('applyCustomRules — srs (local-file mode)', () {
    test('srs с cached path → local rule_set + routing rule', () {
      final reg = RuleSetRegistry();
      final rule = CustomRule(
        id: 'rule-1',
        name: 'GeoIP CN',
        kind: CustomRuleKind.srs,
        srsUrl: 'https://example.com/geoip-cn.srs',
        target: 'direct-out',
      );
      final warn = applyCustomRules(reg, [rule], srsPaths: {
        'rule-1': '/cache/rule_sets/rule-1.srs',
      });
      expect(warn, isEmpty);
      final set = reg.getRuleSets().single;
      expect(set['type'], 'local');
      expect(set['tag'], 'GeoIP CN');
      expect(set['format'], 'binary');
      expect(set['path'], '/cache/rule_sets/rule-1.srs');
      expect(set.containsKey('url'), isFalse);
      expect(set.containsKey('update_interval'), isFalse);
      expect(reg.getRules().single,
          {'rule_set': 'GeoIP CN', 'outbound': 'direct-out'});
    });

    test('srs без cached path → skip + warning', () {
      final reg = RuleSetRegistry();
      final rule = CustomRule(
        id: 'r2',
        name: 'Not yet downloaded',
        kind: CustomRuleKind.srs,
        srsUrl: 'https://example.com/foo.srs',
        target: 'vpn-1',
      );
      final warn = applyCustomRules(reg, [rule]);
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), isEmpty);
      expect(warn, hasLength(1));
      expect(warn.first, contains('Not yet downloaded'));
    });

    test('srs + ports + packages + protocol → AND на routing rule level', () {
      final reg = RuleSetRegistry();
      final rule = CustomRule(
        id: 'r3',
        name: 'SRS filtered',
        kind: CustomRuleKind.srs,
        srsUrl: 'https://example.com/rules.srs',
        ports: ['443'],
        portRanges: ['8000:9000'],
        packages: ['org.mozilla.firefox'],
        protocols: ['tls'],
        target: 'vpn-1',
      );
      applyCustomRules(reg, [rule],
          srsPaths: {'r3': '/cache/rule_sets/r3.srs'});
      final r = reg.getRules().single;
      expect(r['rule_set'], 'SRS filtered');
      expect(r['port'], [443]);
      expect(r['port_range'], ['8000:9000']);
      expect(r['package_name'], ['org.mozilla.firefox']);
      expect(r['protocol'], ['tls']);
      expect(r['outbound'], 'vpn-1');
    });
  });

  group('CustomRule JSON round-trip', () {
    test('inline со всеми полями', () {
      final src = CustomRule(
        id: 'id-x',
        name: 'Mixed',
        domains: ['a.com'],
        domainSuffixes: ['b.com'],
        ports: ['443'],
        portRanges: ['8000:9000'],
        protocols: ['tls'],
        target: kRejectTarget,
      );
      final back = CustomRule.fromJson(src.toJson());
      expect(back.id, 'id-x');
      expect(back.name, 'Mixed');
      expect(back.kind, CustomRuleKind.inline);
      expect(back.domains, ['a.com']);
      expect(back.domainSuffixes, ['b.com']);
      expect(back.ports, ['443']);
      expect(back.portRanges, ['8000:9000']);
      expect(back.protocols, ['tls']);
      expect(back.target, kRejectTarget);
    });

    test('srs kind preserved', () {
      final src = CustomRule(
        name: 'Remote',
        kind: CustomRuleKind.srs,
        srsUrl: 'https://example.com/rules.srs',
        target: 'vpn-1',
      );
      final back = CustomRule.fromJson(src.toJson());
      expect(back.kind, CustomRuleKind.srs);
      expect(back.srsUrl, 'https://example.com/rules.srs');
    });
  });

  group('CustomRule.summary', () {
    test('пустой inline → empty', () {
      expect(CustomRule(name: 'x').summary, '');
    });

    test('inline с полями → разделённый dot', () {
      final s = CustomRule(
        name: 'x',
        domainSuffixes: ['a', 'b'],
        ports: ['443'],
        protocols: ['tls'],
      ).summary;
      expect(s, contains('2 suffix'));
      expect(s, contains('1 port'));
      expect(s, contains('1 proto'));
    });

    test('srs → хост из URL', () {
      final s = CustomRule(
        name: 'x',
        kind: CustomRuleKind.srs,
        srsUrl: 'https://rules.example.com/geo.srs',
      ).summary;
      expect(s, 'SRS: rules.example.com');
    });
  });
}
