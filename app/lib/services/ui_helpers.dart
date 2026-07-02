import 'package:flutter/material.dart';

/// §219 — общий snackbar-хелпер для State'ов. До этого `_snack`/`_showSnack`
/// дублировались приватно в backup/debug/warp_wizard/add_server_wizard экранах.
///
/// Mixin (а не extension на BuildContext): `mounted` здесь — `State.mounted`,
/// поэтому `use_build_context_synchronously`-линт доволен guard'ом внутри, и
/// call-site'ам не нужны свои проверки после await.
mixin SnackHelper<T extends StatefulWidget> on State<T> {
  /// Показать snackbar, если State ещё смонтирован. [duration] — опционально
  /// (по умолчанию материаловские 4s; экраны-визарды раньше ставили 2s).
  void showSnack(String message, {Duration? duration}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: duration ?? const Duration(seconds: 4)),
    );
  }
}
