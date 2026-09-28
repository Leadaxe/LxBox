import 'dart:async';

import 'package:flutter/material.dart';

import '../services/l10n/locale_controller.dart';

/// Задача 583 — выход с главного экрана по двойному нажатию «назад».
///
/// Первое нажатие показывает «Press back again to exit» и на [window]
/// разрешает выход; второе в этом окне уходит системе, и приложение
/// закрывается, как раньше. После окна нажатие снова считается первым.
///
/// `PopScope.canPop` управляется состоянием: пока выход не разрешён, система
/// знает, что «назад» обрабатывает приложение, и предиктивный жест Android 13+
/// не показывает анимацию закрытия.
///
/// Боковое меню — не отдельный маршрут, а запись истории текущего: при
/// `canPop: false` «назад» его бы не закрыл. Поэтому, пока меню открыто,
/// `canPop` истинно, и «назад» закрывает меню без сообщения. Состояние меню
/// приходит через `onDrawerChanged` из [builder] (его отдают в
/// `Scaffold.onDrawerChanged`). Диалоги, листы, выпадающие списки и экраны
/// поверх — свои маршруты: «назад» до этого экрана не доходит.
class DoubleBackToExit extends StatefulWidget {
  const DoubleBackToExit({
    super.key,
    required this.builder,
    this.window = const Duration(seconds: 2),
  });

  final Widget Function(
    BuildContext context,
    ValueChanged<bool> onDrawerChanged,
  )
  builder;

  /// Окно второго нажатия; столько же держится сообщение.
  final Duration window;

  @override
  State<DoubleBackToExit> createState() => _DoubleBackToExitState();
}

class _DoubleBackToExitState extends State<DoubleBackToExit> {
  bool _drawerOpen = false;
  bool _armed = false;
  Timer? _disarm;

  @override
  void dispose() {
    _disarm?.cancel();
    super.dispose();
  }

  void _onDrawerChanged(bool open) {
    if (open == _drawerOpen || !mounted) return;
    setState(() => _drawerOpen = open);
  }

  void _onBack(bool didPop, Object? _) {
    // didPop — закрылось меню (запись истории маршрута): сообщения нет.
    if (didPop || _drawerOpen) return;
    _disarm?.cancel();
    setState(() => _armed = true);
    _disarm = Timer(widget.window, () {
      if (mounted) setState(() => _armed = false);
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(getLocalText.s("Press back again to exit")),
          duration: widget.window,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: _drawerOpen || _armed,
      onPopInvokedWithResult: _onBack,
      child: widget.builder(context, _onDrawerChanged),
    );
  }
}
