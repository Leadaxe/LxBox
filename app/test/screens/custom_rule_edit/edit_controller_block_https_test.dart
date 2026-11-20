import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/screens/custom_rule_edit/edit_controller.dart';

// §755 — Block HTTPS/SVCB records в редакторе: автогалка на переходе
// «домены пусто → не пусто», доступность только при условии по домену,
// ручное снятие не возвращается, сохранённое правило при открытии не
// меняется. Уровень контроллера.

CustomRuleEditController _ctrl(CustomRule initial) => CustomRuleEditController(
      initial: initial,
      preset: null,
      existingNames: const {},
    );

CustomRuleEditController _empty() =>
    _ctrl(CustomRuleInline(id: 'r1', name: 'r', outbound: 'vpn-1'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('§755 Block HTTPS/SVCB records в редакторе', () {
    test('без доменов недоступна и не стоит', () {
      final c = _empty();
      expect(c.blockHttpsAvailable, isFalse);
      expect(c.dns?.blockHttps ?? false, isFalse);
    });

    test('ввод домена в пустое поле ставит галку', () {
      final c = _empty();
      c.domainSuffixCtrl.text = 'rutracker.org';
      expect(c.blockHttpsAvailable, isTrue);
      expect(c.dns!.blockHttps, isTrue);
    });

    test('снятая руками галка при дальнейшем вводе не возвращается', () {
      final c = _empty();
      c.domainCtrl.text = 'a.com';
      c.setBlockHttps(false);
      c.domainCtrl.text = 'a.com\nb.com';
      expect(c.dns?.blockHttps ?? false, isFalse);
    });

    test('стёрли домены и ввели заново — галка ставится снова', () {
      final c = _empty();
      c.domainCtrl.text = 'a.com';
      c.setBlockHttps(false);
      c.domainCtrl.text = '';
      c.domainCtrl.text = 'b.com';
      expect(c.dns!.blockHttps, isTrue);
    });

    test('сохранённое правило с доменами при открытии галку не получает', () {
      final c = _ctrl(CustomRuleInline(
        id: 'r2',
        name: 'old',
        domains: const ['a.com'],
        outbound: 'vpn-1',
      ));
      c.domainCtrl.text = 'a.com\nb.com';
      expect(c.dns?.blockHttps ?? false, isFalse);
      expect(c.blockHttpsAvailable, isTrue);
    });

    test('Save без доменов не несёт blockHttps', () {
      final c = _empty();
      c.domainCtrl.text = 'a.com';
      c.domainCtrl.text = '';
      expect(c.snapshot().dns?.blockHttps ?? false, isFalse);
    });

    test('srs: доступна, по умолчанию выключена', () {
      final c = _ctrl(CustomRuleSrs(
          id: 's1', name: 's', srsUrl: 'https://e/x.srs', outbound: 'vpn-1'));
      expect(c.blockHttpsAvailable, isTrue);
      expect(c.dns?.blockHttps ?? false, isFalse);
    });

    test('порт или network — подсказка «на любом порту», не гейт', () {
      final c = _empty();
      c.domainCtrl.text = 'a.com';
      expect(c.dnsAppliesAnyPort, isFalse);
      c.portCtrl.text = '443';
      expect(c.dnsAppliesAnyPort, isTrue);
      expect(c.blockHttpsAvailable, isTrue);
    });
  });
}
