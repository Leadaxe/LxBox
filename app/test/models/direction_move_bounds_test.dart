import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';

// §673 — запретные зоны перестановки Направлений по правилу 026
// «Other directions — только Направления выше». Границы — конечный индекс
// в списке без перетаскиваемого (семантика `onReorderItem`).
void main() {
  const a = Direction(tag: 'a', label: 'A');
  const b = Direction(tag: 'b', label: 'B', include: ['a']);
  const c = Direction(tag: 'c', label: 'C', enabled: false);
  const d = Direction(tag: 'd', label: 'D', include: ['c']);
  const e = Direction(tag: 'e', label: 'E');
  const list = [a, b, c, d, e];

  test('C — нельзя ниже D (выключенное участвует как обычное)', () {
    final r = directionMoveBounds(list, 2);
    expect((r.min, r.max), (0, 2)); // [A,B,D,E]: выше D — индекс ≤ 2
    expect(r.includedBy?.tag, 'd');
    expect(r.includesAbove, isNull);
  });

  test('A — нельзя ниже B', () {
    final r = directionMoveBounds(list, 0);
    expect((r.min, r.max), (0, 0));
    expect(r.includedBy?.tag, 'b');
  });

  test('D — нельзя выше C', () {
    final r = directionMoveBounds(list, 3);
    expect((r.min, r.max), (3, 4)); // [A,B,C,E]: ниже C — индекс ≥ 3
    expect(r.includesAbove?.tag, 'c');
    expect(r.includedBy, isNull);
  });

  test('E — зон нет', () {
    final r = directionMoveBounds(list, 4);
    expect((r.min, r.max), (0, 4));
    expect(r.includedBy, isNull);
    expect(r.includesAbove, isNull);
  });

  test('ссылка, уже стоящая вниз, зону не порождает', () {
    const x = Direction(tag: 'x', label: 'X', include: ['y']);
    const y = Direction(tag: 'y', label: 'Y');
    final r = directionMoveBounds(const [x, y], 0);
    expect((r.min, r.max), (0, 1));
  });

  group('directionOrderConflicts', () {
    test('новая ссылка вниз — конфликт, старая — нет', () {
      expect(directionOrderConflicts(const [a, b, d, c, e], before: list), [
        (direction: 'd', includes: 'c', reason: kIncludeNotAbove),
      ]);
      const legacy = [
        Direction(tag: 'x', label: 'X', include: ['z']),
        Direction(tag: 'y', label: 'Y'),
        Direction(tag: 'z', label: 'Z'),
      ];
      expect(
          directionOrderConflicts([legacy[1], legacy[0], legacy[2]],
              before: legacy),
          isEmpty);
    });
  });

  group('directionIncludeConflicts', () {
    test('выше и свёртка — ок; ниже, сам, неизвестный — конфликт', () {
      expect(
        directionIncludeConflicts(list, 'c', ['a', 'fold', 'd', 'c', 'zz'],
            foldTags: {'fold'}),
        [
          (direction: 'c', includes: 'd', reason: kIncludeNotAbove),
          (direction: 'c', includes: 'c', reason: kIncludeSelf),
          (direction: 'c', includes: 'zz', reason: kIncludeUnknown),
        ],
      );
      // Нового Направления нет в списке — встаёт последним, всё выше.
      expect(directionIncludeConflicts(list, 'new', ['e', 'a']), isEmpty);
    });
  });
}
