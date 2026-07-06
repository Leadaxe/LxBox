import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/services/debug/handlers/rules.dart';
import 'package:lxbox/services/debug/serializers/rules.dart';

/// §255 — read/write симметрия DNS-опции правила в Debug API.
///
/// Read: `serializeCustomRule` → `dns.force_ipv4` (когда true).
/// Write: `ruleFromJsonStrictForTest` (тест-хук над `_ruleFromJsonStrict`)
/// парсит `force_ipv4` + допускает forceIpv4-only (без server_tag/enabled).
void main() {
  Map<String, dynamic> baseInline(Map<String, dynamic> dns) => {
        'name': 'r',
        'kind': 'inline',
        'domain_suffixes': ['ru'],
        'outbound': 'direct-out',
        'dns': dns,
      };

  group('Debug API RuleDns write (§255)', () {
    test('force_ipv4-only (без server_tag, enabled опущен) → парсится', () {
      final rule = ruleFromJsonStrictForTest(
        baseInline({'force_ipv4': true}),
      );
      expect(rule.dns, isNotNull);
      expect(rule.dns!.forceIpv4, true);
      expect(rule.dns!.enabled, false);
      expect(rule.dns!.serverTag, '');
      expect(rule.forceIpv4Active, true, reason: 'домены есть, галка есть');
    });

    test('enabled=true + server_tag + force_ipv4 → все три', () {
      final rule = ruleFromJsonStrictForTest(
        baseInline({
          'enabled': true,
          'server_tag': 'google_udp',
          'force_ipv4': true,
        }),
      );
      expect(rule.dns!.enabled, true);
      expect(rule.dns!.serverTag, 'google_udp');
      expect(rule.dns!.forceIpv4, true);
    });

    test('enabled=true без server_tag → BadRequest (dedicated-server-mirror '
        'без tag бессмыслен)', () {
      expect(
        () => ruleFromJsonStrictForTest(baseInline({'enabled': true})),
        throwsA(anything),
      );
    });
  });

  group('Debug API RuleDns read (§255)', () {
    test('serializeCustomRule отдаёт dns.force_ipv4 когда true', () async {
      final built = CustomRuleInline(
        name: 'r',
        domainSuffixes: ['ru'],
        outbound: 'direct-out',
        dns: const RuleDns(forceIpv4: true),
      );
      final wire = await serializeCustomRule(built);
      final dns = wire['dns'] as Map<String, Object?>;
      expect(dns['force_ipv4'], true);

      // Round-trip: read → write сохраняет force_ipv4.
      final parsed = ruleFromJsonStrictForTest({
        'name': 'r',
        'kind': 'inline',
        'domain_suffixes': ['ru'],
        'outbound': 'direct-out',
        'dns': dns,
      });
      expect(parsed.dns!.forceIpv4, true);
    });

    test('force_ipv4 скрыт когда false (симметрия с resolve-полями)',
        () async {
      final built = CustomRuleInline(
        name: 'r',
        domainSuffixes: ['ru'],
        outbound: 'direct-out',
        dns: const RuleDns(enabled: true, serverTag: 'google_udp'),
      );
      final wire = await serializeCustomRule(built);
      final dns = wire['dns'] as Map<String, Object?>;
      expect(dns.containsKey('force_ipv4'), false);
    });
  });
}
