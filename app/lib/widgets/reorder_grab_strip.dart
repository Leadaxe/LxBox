import 'package:flutter/material.dart';

/// §098 — единый «grab strip» для drag-reorder списков (routing rules / DNS
/// rules / subscriptions). Вертикальная тонированная полоса слева с иконкой
/// `drag_indicator`. Оборачивается в [ReorderableDragStartListener], поэтому
/// работает с `ReorderableListView(buildDefaultDragHandles: false)`.
///
/// Ставить первым ребёнком `Row(crossAxisAlignment: stretch)` внутри
/// `IntrinsicHeight` — полоса растягивается на высоту строки.
class ReorderGrabStrip extends StatelessWidget {
  const ReorderGrabStrip({super.key, required this.index});

  /// Индекс элемента в `ReorderableListView` (для drag-старта).
  final int index;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ReorderableDragStartListener(
      index: index,
      child: Container(
        width: 18,
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(Icons.drag_indicator, size: 16, color: cs.onSurfaceVariant),
      ),
    );
  }
}
