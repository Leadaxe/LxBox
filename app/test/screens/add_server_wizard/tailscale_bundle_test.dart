import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/node_sections.dart';
import 'package:lxbox/screens/add_server_wizard/tailscale_bundle.dart';

/// §435 — каноническая связка мастера Tailscale: ровно спека §2
/// (правило `@{self} network` на 945 → `@self`, DNS-сервер `@{self}-dns`
/// типа tailscale на `@self`, DNS-правило `.ts.net` → `@{self}-dns`).
void main() {
  test('три записи, плейсхолдеры как есть', () {
    final s = canonicalTailscaleSections();
    expect(s.recordCount, 3);

    final rule = s.rules.single;
    expect(rule.kind, CustomRuleKind.inline);
    expect(rule.name, '@{self} network');
    expect(rule.orderNum, kNodeRuleDefaultNum);
    expect(rule.ipCidrs, ['100.64.0.0/10']);
    expect(rule.outbound, '@self');

    final server = s.dnsServers.single;
    expect(server.tag, '@{self}-dns');
    expect(server.enabled, isTrue);
    expect(server.body, {'type': 'tailscale', 'endpoint': '@self'});

    final dnsRule = s.dnsRules.single;
    expect(dnsRule.name, '');
    expect(dnsRule.enabled, isTrue);
    expect(dnsRule.rule, {
      'domain_suffix': ['.ts.net'],
      'server': '@{self}-dns',
    });
  });

  test('форма §2 переживает кодек (toJson ≡ вход без сгенерированного id)', () {
    final json = canonicalTailscaleSections().toJson();
    final rule = (json['rules'] as List).single as Map<String, dynamic>;
    // `id` у inline-правила кодек генерирует — единственное отличие от входа.
    expect(rule.remove('id'), isA<String>());
    expect(json, canonicalTailscaleSectionsJson());
  });

  test('подстановка финального тега во все три записи', () {
    final s = canonicalTailscaleSections().substituteSelf('🪢 home');
    expect(s.rules.single.name, '🪢 home network');
    expect(s.rules.single.outbound, '🪢 home');
    expect(s.dnsServers.single.tag, '🪢 home-dns');
    expect(s.dnsServers.single.body['endpoint'], '🪢 home');
    expect(s.dnsRules.single.rule['server'], '🪢 home-dns');
  });

  test('каждый вызов — независимый экземпляр', () {
    final a = canonicalTailscaleSections();
    final b = canonicalTailscaleSections();
    expect(identical(a, b), isFalse);
    expect(identical(a.rules.single, b.rules.single), isFalse);
  });
}
