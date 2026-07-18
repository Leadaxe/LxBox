import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/l10n/get_local_text.dart';
import 'package:lxbox/services/l10n/plural_resolver.dart';

/// §285 — движок getLocalText: fallback на ключ, простые/особые формы, плюрал
/// через RuPluralResolver, printf (%s/%d/%1$s/%%), защита от промахов.
void main() {
  // Образец ru-словаря по формату спеки.
  final ruDict = <String, dynamic>{
    'Connected to %s': {'value': 'Подключено к %s'},
    'New': {
      'value': 'Новый',
      'special': {
        '1': {'value': 'Новая'},
      },
    },
    '%d servers': {
      'value': {
        'one': '%d сервер',
        'few': '%d сервера',
        'many': '%d серверов',
        'other': '%d сервера',
      },
    },
    '%d items': {
      'value': {
        'one': '%d элемент',
        'few': '%d элемента',
        'many': '%d элементов',
        'other': '%d элемента',
      },
      'special': {
        '1': {
          'value': {
            'one': '%d шт.',
            'few': '%d шт.',
            'many': '%d шт.',
            'other': '%d шт.',
          },
        },
      },
    },
    'Show %1\$s before %2\$s': {'value': 'Сначала %2\$s, потом %1\$s'},
    '100%% done': {'value': 'Готово на 100%%'},
  };

  GetLocalText ru() => GetLocalText(ruDict, const RuPluralResolver());
  GetLocalText fallback() => GetLocalText(null, const EnPluralResolver());

  group('.s — fallback (dict == null)', () {
    test('prints the English key substituted', () {
      expect(fallback().s('Connected to %s', 'host'), 'Connected to host');
    });

    test('missing key → key itself substituted', () {
      expect(ru().s('No such key %s', 'x'), 'No such key x');
    });
  });

  group('.s — simple value', () {
    test('translated string, %s substituted', () {
      expect(ru().s('Connected to %s', 'srv'), 'Подключено к srv');
    });

    test('no-arg key', () {
      expect(ru().s('New'), 'Новый');
    });
  });

  group('.s — special form index', () {
    test('form 1 → special["1"]', () {
      expect(ru().s(1, 'New'), 'Новая');
    });

    test('missing special index → key fallback', () {
      expect(ru().s(2, 'New'), 'New');
    });
  });

  group('.plural — ru forms', () {
    test('1 → one', () => expect(ru().plural('%d servers', 1), '1 сервер'));
    test('2 → few', () => expect(ru().plural('%d servers', 2), '2 сервера'));
    test('5 → many', () => expect(ru().plural('%d servers', 5), '5 серверов'));
    test('22 → few', () => expect(ru().plural('%d servers', 22), '22 сервера'));
    test(
        '25 → many', () => expect(ru().plural('%d servers', 25), '25 серверов'));
  });

  group('.plural — special index + plural', () {
    test('form 1 plural via special', () {
      expect(ru().plural(1, '%d items', 3), '3 шт.');
    });
  });

  group('.plural — fallback', () {
    test('dict null → English key substituted with %d', () {
      expect(fallback().plural('%d servers', 7), '7 servers');
    });

    test('missing key → key substituted', () {
      expect(ru().plural('%d widgets', 4), '4 widgets');
    });
  });

  group('printf', () {
    test('%1\$s / %2\$s reorder', () {
      expect(ru().s('Show %1\$s before %2\$s', 'A', 'B'), 'Сначала B, потом A');
    });

    test('%% literal', () {
      expect(ru().s('100%% done'), 'Готово на 100%');
    });

    test('%d truncates num', () {
      expect(fallback().plural('%d servers', 3.9), '3 servers');
    });

    test('missing arg → empty placeholder', () {
      expect(fallback().s('a %s b %s c', 'X'), 'a X b  c');
    });
  });

  group('robustness', () {
    test('.s never throws on plural-object value → key fallback', () {
      // Звали .s на ключ с plural-объектом value — печатаем ключ (не сырой JSON),
      // printf-substituted теми же (пустыми) аргументами: %d → пусто.
      expect(ru().s('%d servers'), ' servers');
    });
  });
}
