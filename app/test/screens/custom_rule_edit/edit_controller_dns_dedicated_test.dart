import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/screens/custom_rule_edit/edit_controller.dart';

// §711 — выбор Dedicated server и сервера в Answer включает «Resolve before
// routing» и ставит сервер резолва = сервер Answer. Уровень контроллера.

CustomRuleEditController _ctrl({RuleDns? dns, RuleResolve? resolve}) =>
    CustomRuleEditController(
      initial: CustomRuleInline(
        id: 'r1',
        name: 'gov',
        domains: const ['gosuslugi.ru'],
        outbound: 'direct-out',
        dns: dns,
        resolve: resolve,
      ),
      preset: null,
      existingNames: const {},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('§711 Dedicated ставит Resolve before routing', () {
    test('выбор Dedicated → resolve с сервером Answer', () {
      final c = _ctrl(dns: const RuleDns(serverTag: 'dns_ru'));
      expect(c.resolve, isNull);
      c.setDnsAnswerMode(DnsAnswerMode.dedicated);
      expect(c.resolve, isNotNull);
      expect(c.resolve!.only, isFalse);
      expect(c.resolve!.serverTag, 'dns_ru');
    });

    test('смена сервера в Answer меняет resolve.serverTag', () {
      final c = _ctrl(dns: const RuleDns(serverTag: 'dns_ru'));
      c.setDnsAnswerMode(DnsAnswerMode.dedicated);
      c.setDnsServerTag('google_doh');
      expect(c.resolve!.serverTag, 'google_doh');
    });

    test('снятие галки после — resolve == null', () {
      final c = _ctrl(dns: const RuleDns(serverTag: 'dns_ru'));
      c.setDnsAnswerMode(DnsAnswerMode.dedicated);
      c.setResolveFirst(false);
      expect(c.resolve, isNull);
    });

    test('включённый resolve: сервер перезаписан, strategy сохранена', () {
      final c = _ctrl(
        dns: const RuleDns(serverTag: 'dns_ru'),
        resolve: const RuleResolve(
            serverTag: 'google_doh', strategy: 'ipv4_only'),
      );
      c.setDnsAnswerMode(DnsAnswerMode.dedicated);
      expect(c.resolve!.serverTag, 'dns_ru');
      expect(c.resolve!.strategy, 'ipv4_only');
    });

    test('возврат на Default — resolve остаётся', () {
      final c = _ctrl(dns: const RuleDns(serverTag: 'dns_ru'));
      c.setDnsAnswerMode(DnsAnswerMode.dedicated);
      c.setDnsAnswerMode(DnsAnswerMode.defaultDns);
      expect(c.resolve, isNotNull);
      expect(c.resolve!.serverTag, 'dns_ru');
    });

    test('гидрация Dedicated без resolve ничего не включает', () {
      final c = _ctrl(dns: const RuleDns(enabled: true, serverTag: 'dns_ru'));
      expect(c.resolve, isNull);
    });

    test('snapshot содержит resolve с сервером', () {
      final c = _ctrl(dns: const RuleDns(serverTag: 'dns_ru'));
      c.setDnsAnswerMode(DnsAnswerMode.dedicated);
      final snap = c.snapshot() as CustomRuleInline;
      expect(snap.resolve, isNotNull);
      expect(snap.resolve!.serverTag, 'dns_ru');
      expect(snap.dns!.serverTag, 'dns_ru');
    });
  });
}
