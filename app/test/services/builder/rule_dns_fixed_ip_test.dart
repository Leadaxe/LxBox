import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/codec/rule_record.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';

/// Правило через запись `rules[]` и обратно — путь хранения (§439).
CustomRule _roundTrip(CustomRule r) =>
    ruleFromRecord(ruleToRecord(r), unknownAsVerbatim: true).value!;

UnifiedApplyResult _apply(CustomRule r, {Map<String, String>? srsPaths}) =>
    applyAllCustomRules(RuleSetRegistry(), [r], const [],
        srsPaths: srsPaths ?? const {});

/// §683 — Answer = Fixed IP: модель, хранение, эмиссия `predefined`.
void main() {
  group('RuleDns Fixed IP — модель и хранение', () {
    test('режимы Answer: fixedMode приоритетнее enabled, пустой список — нет',
        () {
      expect(const RuleDns(fixed: true, fixedIps: ['1.2.3.4']).fixedMode, true);
      expect(const RuleDns(fixed: true).fixedMode, false);
      expect(const RuleDns(fixedIps: ['1.2.3.4']).fixedMode, false);
      final r = CustomRuleInline(
        name: 'r',
        domains: ['a.com'],
        outbound: 'direct-out',
        dns: const RuleDns(
            enabled: true,
            serverTag: 'google_udp',
            forceIpv4: true,
            fixed: true,
            fixedIps: ['1.2.3.4']),
      );
      expect(r.dnsFixedActive, true);
      expect(r.dnsMirrorActive, false);
      expect(r.forceIpv4Active, false);
    });

    test('round-trip fixed + fixedIps; выключенный режим хранит адреса', () {
      final on = CustomRuleInline(
        name: 'nas',
        domains: ['nas.home'],
        outbound: 'direct-out',
        dns: const RuleDns(fixed: true, fixedIps: ['192.168.1.10', 'fd00::1']),
      );
      final rec = ruleToRecord(on)['dns'] as Map;
      expect(rec['fixed'], true);
      expect(rec['fixedIps'], ['192.168.1.10', 'fd00::1']);
      expect(_roundTrip(on).dns, on.dns);

      final off = on.copyWith(
          dns: const RuleDns(serverTag: 'x', fixedIps: ['192.168.1.10']));
      final offRec = ruleToRecord(off)['dns'] as Map;
      expect(offRec.containsKey('fixed'), false);
      expect(_roundTrip(off).dns!.fixedIps, ['192.168.1.10']);
    });

    test('старая запись без новых ключей читается как раньше', () {
      final old = CustomRuleInline(
        name: 'old',
        domains: ['a.com'],
        outbound: 'direct-out',
        dns: const RuleDns(enabled: true, serverTag: 'google_udp'),
      );
      final rec = ruleToRecord(old)['dns'] as Map;
      expect(rec.keys.toSet(), {'enabled', 'serverTag'});
      final back = _roundTrip(old);
      expect(back.dns!.fixed, false);
      expect(back.dns!.fixedIps, isEmpty);
      expect(back.dnsMirrorActive, true);
    });

    test('ipRecordType', () {
      expect(RuleDns.ipRecordType('192.168.1.10'), 'A');
      expect(RuleDns.ipRecordType(' fd00::10 '), 'AAAA');
      expect(RuleDns.ipRecordType('1.2.3'), isNull);
      expect(RuleDns.ipRecordType('nas.home'), isNull);
      expect(RuleDns.ipRecordType(''), isNull);
    });
  });

  group('эмиссия Fixed IP', () {
    test('inline, только IPv4: A с answer, AAAA пустой NOERROR', () {
      final r = CustomRuleInline(
        name: 'nas',
        domains: ['nas.home'],
        outbound: 'direct-out',
        dns: const RuleDns(fixed: true, fixedIps: ['192.168.1.10', '10.0.0.2']),
      );
      final m = _apply(r).dnsMirrors;
      expect(m, hasLength(2));
      expect(m.every((e) => e.serverless && e.fixedAnswer), true);
      expect(m[0].body, {
        'rule_set': 'nas',
        'query_type': ['A'],
        'action': 'predefined',
        'rcode': 'NOERROR',
        'answer': ['*. 300 IN A 192.168.1.10', '*. 300 IN A 10.0.0.2'],
      });
      expect(m[1].body, {
        'rule_set': 'nas',
        'query_type': ['AAAA'],
        'action': 'predefined',
        'rcode': 'NOERROR',
      });
    });

    test('inline, только IPv6: A пустой, AAAA с answer', () {
      final r = CustomRuleInline(
        name: 'v6',
        domains: ['h.lan'],
        outbound: 'direct-out',
        dns: const RuleDns(fixed: true, fixedIps: ['fd00::10']),
      );
      final m = _apply(r).dnsMirrors;
      expect(m[0].body.containsKey('answer'), false);
      expect(m[0].body['query_type'], ['A']);
      expect(m[1].body['answer'], ['*. 300 IN AAAA fd00::10']);
    });

    test('оба семейства; Force IPv4 и сервер при Fixed IP не эмитятся', () {
      final r = CustomRuleInline(
        name: 'both',
        domains: ['h.lan'],
        outbound: 'direct-out',
        dns: const RuleDns(
            enabled: true,
            serverTag: 'google_udp',
            forceIpv4: true,
            fixed: true,
            fixedIps: ['1.2.3.4', 'fd00::1']),
      );
      final m = _apply(r).dnsMirrors;
      expect(m, hasLength(2));
      expect(m[0].body['answer'], ['*. 300 IN A 1.2.3.4']);
      expect(m[1].body['answer'], ['*. 300 IN AAAA fd00::1']);
      expect(m.any((e) => e.body.containsKey('ip_version')), false);
      expect(m.any((e) => e.serverTag.isNotEmpty), false);
    });

    test('srs: матч = .srs-тег + доп-фильтры', () {
      final r = CustomRuleSrs(
        name: 'lst',
        srsUrl: 'https://e/l.srs',
        packages: ['com.app'],
        outbound: 'vpn-1',
        dns: const RuleDns(fixed: true, fixedIps: ['1.2.3.4']),
      );
      final m = _apply(r, srsPaths: {r.id: '/tmp/l.srs'}).dnsMirrors;
      expect(m, hasLength(2));
      expect(m[0].body['rule_set'], 'lst');
      expect(m[0].body['package_name'], ['com.app']);
      expect(m[0].body['answer'], ['*. 300 IN A 1.2.3.4']);
    });

    test('ports → гейт, Fixed IP не эмитится; fixed без адресов — тоже', () {
      final gated = CustomRuleInline(
        name: 'g',
        domains: ['a.com'],
        ports: ['443'],
        outbound: 'direct-out',
        dns: const RuleDns(fixed: true, fixedIps: ['1.2.3.4']),
      );
      expect(_apply(gated).dnsMirrors, isEmpty);
      final empty = CustomRuleInline(
        name: 'e',
        domains: ['a.com'],
        outbound: 'direct-out',
        dns: const RuleDns(fixed: true),
      );
      expect(_apply(empty).dnsMirrors, isEmpty);
    });

    test('адреса хранятся, но режим Default — зеркала нет', () {
      final r = CustomRuleInline(
        name: 'd',
        domains: ['a.com'],
        outbound: 'direct-out',
        dns: const RuleDns(fixedIps: ['1.2.3.4']),
      );
      expect(_apply(r).dnsMirrors, isEmpty);
    });
  });
}
