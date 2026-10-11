import 'dart:async';

import 'package:flutter/material.dart';

import '../services/ui_helpers.dart';

/// §626 — шторка с явной кнопкой Save: при несохранённых правках любой выход
/// (Back, тап по фону, смахивание вниз) спрашивает общий диалог Unsaved
/// changes (§219), как экраны правки.
///
/// Шторку открывать через `showAppBottomSheet(enableDrag: false)`: штатное
/// смахивание закрывает её через `Navigator.pop` мимо `PopScope`. Жест ведёт
/// эта обёртка, но так же, как штатная шторка: двигает анимацию маршрута
/// шторки, шторка и затемнение едут за пальцем. Отпустили выше середины —
/// шторка возвращается; ниже середины или рывком вниз — без правок
/// закрывается, с правками возвращается на место и показывает диалог.
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

/// Пороги и кривая штатной модальной шторки (material/bottom_sheet.dart).
const double _kMinFlingVelocity = 700;
const double _kCloseProgressThreshold = 0.5;
const Curve _kSheetCurve = Easing.legacyDecelerate;

class _UnsavedChangesSheetState extends State<UnsavedChangesSheet> {
  AnimationController? _controller;

  /// Высота шторки на время жеста.
  double _height = 1;

  /// Насколько шторка опущена от места, в пикселях.
  double _offset = 0;

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

  /// Контроллер анимации маршрута шторки: его же двигает штатный жест.
  AnimationController? _routeController() {
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return null;
    // ignore: invalid_use_of_protected_member
    return route.controller;
  }

  /// Значение анимации, при котором шторка видна на долю [shown]: шторка
  /// рисуется по кривой, а палец ведёт её линейно.
  static double _valueFor(double shown) {
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 24; i++) {
      final mid = (lo + hi) / 2;
      if (_kSheetCurve.transform(mid) < shown) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }

  void _onDragStart(DragStartDetails _) {
    final c = _routeController();
    _controller = c;
    if (c == null) return;
    c.stop();
    // Высота всей шторки (Material вокруг контента), как у штатного жеста.
    final sheet = context.findAncestorStateOfType<State<BottomSheet>>();
    _height = sheet?.context.size?.height ?? context.size?.height ?? 1;
    _offset = (1 - _kSheetCurve.transform(c.value)) * _height;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final c = _controller;
    if (c == null) return;
    _offset = (_offset + d.delta.dy).clamp(0.0, _height);
    c.value = _valueFor(1 - _offset / _height);
  }

  void _onDragEnd(DragEndDetails d) {
    final c = _controller;
    _controller = null;
    if (c == null) return;
    final shown = _kSheetCurve.transform(c.value);
    final closing = d.velocity.pixelsPerSecond.dy > _kMinFlingVelocity ||
        shown < _kCloseProgressThreshold;
    if (closing && !widget.isDirty()) {
      // Маршрут доигрывает закрытие с текущего места.
      Navigator.pop(context);
      return;
    }
    unawaited(c.forward());
    if (closing) unawaited(_handleBack());
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
        onVerticalDragStart: _onDragStart,
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        onVerticalDragCancel: () {
          final c = _controller;
          _controller = null;
          if (c != null) unawaited(c.forward());
        },
        child: widget.child,
      ),
    );
  }
}
