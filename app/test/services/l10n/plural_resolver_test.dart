import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/l10n/plural_resolver.dart';

/// §285 — CLDR-корректность resolver'ов. Формы возвращаем как маркеры, чтобы
/// тест читал ВЫБОР формы, а не подставленный текст.
void main() {
  const marked = {
    'one': 'ONE',
    'few': 'FEW',
    'many': 'MANY',
    'other': 'OTHER',
  };

  group('RuPluralResolver', () {
    const r = RuPluralResolver();

    test('forms = one/few/many/other', () {
      expect(r.forms, {'one', 'few', 'many', 'other'});
    });

    void expectForm(num n, String form) =>
        expect(r.select(marked, n), form, reason: 'n=$n');

    test('one: 1, 21', () {
      expectForm(1, 'ONE');
      expectForm(21, 'ONE');
    });

    test('few: 2, 3, 4, 22', () {
      expectForm(2, 'FEW');
      expectForm(3, 'FEW');
      expectForm(4, 'FEW');
      expectForm(22, 'FEW');
    });

    test('many: 5, 11, 12, 13, 14, 25', () {
      expectForm(5, 'MANY');
      expectForm(11, 'MANY');
      expectForm(12, 'MANY');
      expectForm(13, 'MANY');
      expectForm(14, 'MANY');
      expectForm(25, 'MANY');
    });

    test('many: 0', () => expectForm(0, 'MANY'));

    test('non-integer 1.5 → other', () => expectForm(1.5, 'OTHER'));
  });

  group('EnPluralResolver', () {
    const r = EnPluralResolver();

    test('forms = one/other', () {
      expect(r.forms, {'one', 'other'});
    });

    test('1 → one, else other', () {
      const m = {'one': 'ONE', 'other': 'OTHER'};
      expect(r.select(m, 1), 'ONE');
      expect(r.select(m, 0), 'OTHER');
      expect(r.select(m, 2), 'OTHER');
      expect(r.select(m, 21), 'OTHER');
    });
  });
}
