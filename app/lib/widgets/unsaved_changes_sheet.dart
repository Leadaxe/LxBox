import 'dart:async';

import 'package:flutter/material.dart';

import '../services/ui_helpers.dart';

/// §626 — шторка с явной кнопкой Save: при несохранённых правках любой выход
/// (Back, тап по фону, смахивание вниз) спрашивает общий диалог Unsaved
/// changes (§219), как экраны правки.
///
/// Шторку открывать с `enableDrag: false`: штатное смахивание закрывает её
/// через `Navigator.pop` мимо `PopScope`, поэтому жест ведёт эта обёртка и
/// закрывает через `maybePop`.
///
/// [isDirty] — есть ли правки. [onSave] — тот же путь, что кнопка Save
/// шторки: сам закрывает шторку при успехе, при ошибке оставляет открытой.
class UnsavedChangesSheet extends StatefulWidget {
  const UnsavedChangesSheet({
    super.key,
    required this.isDirty,
    required this.onSave,
    required this.child,
  });

  final bool Function() isDirty;
  final Future<void> Function() onSave;
  final Widget child;

  @override
  State<UnsavedChangesSheet> createState() => _UnsavedChangesSheetState();
}

class _UnsavedChangesSheetState extends State<UnsavedChangesSheet> {
  /// Путь пальца вниз за текущий жест.
  double _drag = 0;

  Future<void> _handleBack() async {
    if (!widget.isDirty()) {
      Navigator.pop(context);
      return;
    }
    final action = await showUnsavedChangesDialog(context); // §219
    if (!mounted) return;
    if (action == 'save') {
      await widget.onSave();
    } else if (action == 'discard') {
      Navigator.pop(context);
    }
    // 'keep' / null (dismiss) — остаёмся.
  }

  /// Смахивание вниз (рывок или треть высоты шторки) — как Back.
  void _onDragEnd(DragEndDetails d) {
    final height = context.size?.height ?? 1;
    final closing = d.velocity.pixelsPerSecond.dy > 700 || _drag > height / 3;
    _drag = 0;
    if (closing) unawaited(Navigator.maybePop(context));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragUpdate: (d) => _drag += d.delta.dy,
        onVerticalDragEnd: _onDragEnd,
        child: widget.child,
      ),
    );
  }
}
