import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/node_sections.dart';
import 'package:lxbox/models/tailscale_bundle.dart';
import 'package:lxbox/services/parser/json_parsers.dart';

/// §435/§437 — каноническая связка Tailscale: правило `@{self} network` на
/// 945 (`.ts.net` + обе подсети tailnet → `@self`, с парным `resolve` через
/// DNS-сервер узла), DNS-сервер `@{self}-dns` типа tailscale на `@self`,
/// DNS-правило `.ts.net` → `@{self}-dns`.
void main() {
  test('три записи, плейсхолдеры как есть', () {
    final s = canonicalTailscaleSections();
    expect(s.recordCount, 3);

    final rule = s.rules.single;
    expect(rule.kind, CustomRuleKind.inline);
    expect(rule.name, '@{self} network');
    expect(rule.orderNum, kNodeRuleDefaultNum);
    expect(rule.domainSuffixes, ['.ts.net']);
    expect(rule.ipCidrs, ['100.64.0.0/10', 'fd7a:115c:a1e0::/48']);
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

  test('resolve активен: непустая domain-группа + DNS-сервер узла', () {
    final rule = canonicalTailscaleSections().rules.single;
    expect(rule.resolve, isNotNull);
    expect(rule.resolve!.only, isFalse);
    expect(rule.resolve!.serverTag, '@{self}-dns');
    // Гейт билдера: без domain-группы resolve-правило не эмитится.
    expect(rule.resolveEligible, isTrue);
    expect(rule.resolveActive, isTrue);
  });

  test('форма §2 переживает кодек (toJson ≡ вход без сгенерированного id)', () {
    final json = canonicalTailscaleSections().toJson();
    final rule = (json['rules'] as List).single as Map<String, dynamic>;
    // `id` у inline-правила кодек генерирует — единственное отличие от входа.
    expect(rule.remove('id'), isA<String>());
    expect(json, canonicalTailscaleSectionsJson());
  });

  test('подстановка финального тега во все ссылки, включая resolve.serverTag',
      () {
    final s = canonicalTailscaleSections().substituteSelf('🪢 home');
    expect(s.rules.single.name, '🪢 home network');
    expect(s.rules.single.outbound, '🪢 home');
    expect(s.rules.single.resolve!.serverTag, '🪢 home-dns');
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

  group('§437 sectionsForNewNode', () {
    test('узел Tailscale без извлечённых записей → каноническая связка', () {
      final ts = parseSingboxEntry({'type': 'tailscale', 'tag': 'home-ts'})!;
      expect(ts.importedSections, isNull);
      final s = sectionsForNewNode(ts)!;
      expect(s.recordCount, 3);
      expect(s.rules.single.name, '@{self} network');
    });

    test('извлечённые записи сильнее канонической связки', () {
      final ts = parseSingboxEntry({'type': 'tailscale', 'tag': 'home-ts'})!;
      ts.importedSections = NodeSections.fromJson({
        'rules': [
          {
            'kind': 'inline',
            'name': 'mine',
            'body': {'ip_cidr': ['10.0.0.0/8'], 'outbound': '@self'},
          },
        ],
      });
      expect(sectionsForNewNode(ts)!.rules.single.name, 'mine');
    });

    test('не-Tailscale узел без записей → секций нет', () {
      final v = parseSingboxEntry({
        'type': 'vless',
        'tag': 'v',
        'server': 'a.com',
        'server_port': 443,
        'uuid': 'u',
      })!;
      expect(sectionsForNewNode(v), isNull);
    });
  });
}
