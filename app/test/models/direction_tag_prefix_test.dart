import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/direction_tag_prefix.dart';

/// §393 A6 — смена `tag_prefix` источника молча ломала regex-фильтры
/// Направлений: билдер эмитит тег как `'$prefix $bare'`, а Направление
/// отбирает узлы regex'ом по итоговому тегу. Здесь — разбор паттерна на
/// «литерал / конструкция» и решение чинить-или-предупредить.
void main() {
  group('rewriteLiteralPrefix — однозначные вхождения переписываются', () {
    test('якорь + префикс + разделитель', () {
      final r = rewriteLiteralPrefix('^RU: ', 'RU:', 'DE:');
      expect(r.pattern, '^DE: ');
      expect(r.changed, isTrue);
      expect(r.ambiguous, isFalse);
    });

    test('префикс без якоря, среди конструкций', () {
      final r = rewriteLiteralPrefix(r'^RU: .*\.de$', 'RU:', 'DE:');
      expect(r.pattern, r'^DE: .*\.de$');
      expect(r.changed, isTrue);
      expect(r.ambiguous, isFalse);
    });

    test('экранированный метасимвол внутри префикса — тоже литерал', () {
      final r = rewriteLiteralPrefix(r'^RU\: ', 'RU:', 'DE:');
      expect(r.pattern, '^DE: ');
      expect(r.changed, isTrue);
    });

    test('оба вхождения в альтернативе', () {
      final r = rewriteLiteralPrefix('(RU:|RU:x)', 'RU:', 'DE:');
      expect(r.pattern, '(DE:|DE:x)');
      expect(r.changed, isTrue);
      expect(r.ambiguous, isFalse);
    });

    test('новый префикс экранируется — не становится конструкцией', () {
      final r = rewriteLiteralPrefix('^RU: ', 'RU:', 'D(E)');
      expect(r.pattern, r'^D\(E\) ');
      // Переписанный фильтр обязан ловить ЛИТЕРАЛЬНЫЙ новый тег.
      expect(RegExp(r.pattern).hasMatch('D(E) Frankfurt'), isTrue);
    });

    test('пустой новый префикс — литерал вырезается', () {
      final r = rewriteLiteralPrefix('^RU: x', 'RU:', '');
      expect(r.pattern, '^ x');
      expect(r.changed, isTrue);
    });
  });

  group('rewriteLiteralPrefix — конструкции не угадываются', () {
    test('квантор внутри вхождения → не тронут, предупреждение', () {
      final r = rewriteLiteralPrefix('RU:?', 'RU:', 'DE:');
      expect(r.pattern, 'RU:?', reason: 'паттерн обязан остаться как был');
      expect(r.changed, isFalse);
      expect(r.ambiguous, isTrue);
    });

    test('символ префикса записан классом → не тронут, предупреждение', () {
      final r = rewriteLiteralPrefix('^RU[:]', 'RU:', 'DE:');
      expect(r.pattern, '^RU[:]');
      expect(r.changed, isFalse);
      expect(r.ambiguous, isTrue);
    });

    test('повторитель {n,m} на последнем символе', () {
      final r = rewriteLiteralPrefix('^RU:{1,2}', 'RU:', 'DE:');
      expect(r.changed, isFalse);
      expect(r.ambiguous, isTrue);
    });

    test('битый regex не трогаем вовсе', () {
      final r = rewriteLiteralPrefix('^(RU:', 'RU:', 'DE:');
      expect(r.pattern, '^(RU:');
      expect(r.changed, isFalse);
      expect(r.ambiguous, isTrue);
    });
  });

  group('rewriteLiteralPrefix — тишина', () {
    test('вхождений нет', () {
      final r = rewriteLiteralPrefix(r'Frankfurt|Berlin', 'RU:', 'DE:');
      expect(r.pattern, r'Frankfurt|Berlin');
      expect(r.changed, isFalse);
      expect(r.ambiguous, isFalse);
    });

    test('метасимвол ВМЕСТО символа префикса — это не вхождение', () {
      // `R.:` матчит `RU:`, но написано это НЕ префиксом: пользователь
      // задал шаблон. Ни чинить, ни пугать.
      final r = rewriteLiteralPrefix('R.:', 'RU:', 'DE:');
      expect(r.changed, isFalse);
      expect(r.ambiguous, isFalse);
    });

    test('пустой фильтр', () {
      final r = rewriteLiteralPrefix('', 'RU:', 'DE:');
      expect(r.changed, isFalse);
      expect(r.ambiguous, isFalse);
    });
  });

  group('analyzeTagPrefixChange', () {
    Direction dir(String tag, {String node = '', String def = ''}) =>
        Direction(tag: tag, label: tag, nodeFilter: node, defaultFilter: def);

    test('литеральное вхождение → Направление в healed', () {
      final c = analyzeTagPrefixChange(
        directions: [dir('vpn-1', node: '^RU: ')],
        oldPrefix: 'RU:',
        newPrefix: 'DE:',
      );
      expect(c.impacts, hasLength(1));
      expect(c.impacts.single.healed!.nodeFilter, '^DE: ');
      expect(c.impacts.single.ambiguous, isFalse);
    });

    test('defaultFilter чинится наравне с nodeFilter', () {
      final c = analyzeTagPrefixChange(
        directions: [dir('vpn-1', node: '^RU: ', def: 'RU: Berlin')],
        oldPrefix: 'RU:',
        newPrefix: 'DE:',
      );
      final healed = c.impacts.single.healed!;
      expect(healed.nodeFilter, '^DE: ');
      expect(healed.defaultFilter, 'DE: Berlin');
    });

    test('конструкция → ambiguous, фильтр не тронут', () {
      final c = analyzeTagPrefixChange(
        directions: [dir('vpn-1', node: '^RU[:]')],
        oldPrefix: 'RU:',
        newPrefix: 'DE:',
      );
      expect(c.impacts.single.healed, isNull);
      expect(c.impacts.single.ambiguous, isTrue);
      expect(c.healedDirections, isEmpty);
      expect(c.ambiguousImpacts, hasLength(1));
    });

    test('одно Направление, половина фильтров чинится — обе половины видны',
        () {
      final c = analyzeTagPrefixChange(
        directions: [dir('vpn-1', node: '^RU: ', def: 'RU:?')],
        oldPrefix: 'RU:',
        newPrefix: 'DE:',
      );
      final impact = c.impacts.single;
      expect(impact.healed!.nodeFilter, '^DE: ');
      expect(impact.healed!.defaultFilter, 'RU:?', reason: 'не угадан');
      expect(impact.ambiguous, isTrue);
    });

    test('без вхождений — тихо', () {
      final c = analyzeTagPrefixChange(
        directions: [dir('vpn-1', node: 'Frankfurt'), dir('vpn-2')],
        oldPrefix: 'RU:',
        newPrefix: 'DE:',
      );
      expect(c.isEmpty, isTrue);
    });

    test('пустой СТАРЫЙ префикс каскада не даёт', () {
      // Пустая строка — подстрока любого фильтра; каскад по ней снёс бы всё.
      final c = analyzeTagPrefixChange(
        directions: [dir('vpn-1', node: '^RU: ')],
        oldPrefix: '',
        newPrefix: 'DE:',
      );
      expect(c.isEmpty, isTrue);
    });

    test('префикс не изменился — каскада нет', () {
      final c = analyzeTagPrefixChange(
        directions: [dir('vpn-1', node: '^RU: ')],
        oldPrefix: 'RU:',
        newPrefix: 'RU:',
      );
      expect(c.isEmpty, isTrue);
    });
  });

  group('регрессия: фильтр после каскада реально ловит новый тег', () {
    test('^RU: → ^DE: матчит display-тег нового префикса', () {
      final r = rewriteLiteralPrefix('^RU: ', 'RU:', 'DE:');
      final re = RegExp(r.pattern, caseSensitive: false);
      expect(re.hasMatch('DE: Frankfurt'), isTrue);
      expect(re.hasMatch('RU: Moscow'), isFalse);
    });
  });
}
