/// §606 — перетаскивание узла под активным фильтром.
///
/// Экран видит только часть списка (фильтр §048, скрытые detour-узлы), а
/// ручной порядок (§071/§100) — один на ВСЕ узлы. Раньше новым порядком
/// становился видимый список целиком: скрытые узлы выпадали из
/// `manualOrder`, и сортировка ставила их в хвост как «новые».
///
/// Здесь двигается только [moved]: из полного порядка [fullOrder] (без
/// закреплённых) он вынимается и встаёт сразу после ближайшего видимого
/// соседа сверху по новой позиции в [visibleReordered]; соседа сверху нет —
/// перед ближайшим видимым соседом снизу; нет и его — на прежнее место.
/// Остальные узлы, видимые и скрытые, сохраняют взаимный порядок.
///
/// Соседи, которых нет в [fullOrder] (закреплённый узел, выдавленный фильтром
/// из закреплённой секции в общий список), пропускаются. [moved] вне
/// [fullOrder] — дописывается в конец.
List<String> mergeManualReorder({
  required List<String> fullOrder,
  required List<String> visibleReordered,
  required String moved,
}) {
  final result = List<String>.of(fullOrder);
  final oldAt = result.indexOf(moved);
  if (oldAt < 0) return result..add(moved);
  result.removeAt(oldAt);

  final at = visibleReordered.indexOf(moved);
  if (at >= 0) {
    for (var i = at - 1; i >= 0; i--) {
      final p = result.indexOf(visibleReordered[i]);
      if (p >= 0) return result..insert(p + 1, moved);
    }
    for (var i = at + 1; i < visibleReordered.length; i++) {
      final n = result.indexOf(visibleReordered[i]);
      if (n >= 0) return result..insert(n, moved);
    }
  }
  return result..insert(oldAt, moved);
}
