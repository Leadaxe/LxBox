import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/home/manual_reorder.dart';

/// §606 — перетаскивание под фильтром двигает только перетащенный узел;
/// скрытые узлы остаются на своих местах, а не уезжают в хвост.
void main() {
  // Полный порядок: a..f; фильтр оставил видимыми b, d, f.
  const full = ['a', 'b', 'c', 'd', 'e', 'f'];

  test('скрытые узлы сохраняют места: f перетащен в начало видимых', () {
    final r = mergeManualReorder(
      fullOrder: full,
      visibleReordered: const ['f', 'b', 'd'],
      moved: 'f',
    );
    // Соседа сверху нет → перед ближайшим видимым снизу (b).
    expect(r, ['a', 'f', 'b', 'c', 'd', 'e']);
  });

  test('b перетащен вниз, после d — встаёт сразу за d', () {
    final r = mergeManualReorder(
      fullOrder: full,
      visibleReordered: const ['d', 'b', 'f'],
      moved: 'b',
    );
    expect(r, ['a', 'c', 'd', 'b', 'e', 'f']);
  });

  test('состав не теряется: скрытые не выпадают из порядка', () {
    final r = mergeManualReorder(
      fullOrder: full,
      visibleReordered: const ['b', 'f', 'd'],
      moved: 'f',
    );
    expect(r.toSet(), full.toSet());
    expect(r.length, full.length);
  });

  test('без фильтра — та же перестановка, что у видимого списка', () {
    final r = mergeManualReorder(
      fullOrder: full,
      visibleReordered: const ['a', 'e', 'b', 'c', 'd', 'f'],
      moved: 'e',
    );
    expect(r, ['a', 'e', 'b', 'c', 'd', 'f']);
  });

  test('сосед вне полного порядка (закреплённый) пропускается', () {
    final r = mergeManualReorder(
      fullOrder: full,
      visibleReordered: const ['d', 'pinned', 'b', 'f'],
      moved: 'b',
    );
    expect(r, ['a', 'c', 'd', 'b', 'e', 'f']);
  });

  test('единственный видимый узел остаётся на месте', () {
    final r = mergeManualReorder(
      fullOrder: full,
      visibleReordered: const ['c'],
      moved: 'c',
    );
    expect(r, full);
  });
}
