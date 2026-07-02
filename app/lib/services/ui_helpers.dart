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

/// §219 — единый диалог «Unsaved changes» (Discard / Keep / Save). Был
/// идентично продублирован в channel_edit / custom_rule_edit / dns_server_edit
/// (`_handleBack`). Возвращает `'save'` / `'discard'` / `'keep'` / `null`
/// (dismiss). Стилизация: Discard — `colorScheme.error`, Save — bold primary.
Future<String?> showUnsavedChangesDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return AlertDialog(
        title: const Text('Unsaved changes'),
        content: const Text('You have unsaved changes. Save before leaving?'),
        // §045 — все TextButton + короткие надписи вмещаются в строку.
        actionsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            style: TextButton.styleFrom(foregroundColor: cs.error),
            child: const Text('Discard'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'keep'),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            style: TextButton.styleFrom(
              foregroundColor: cs.primary,
              textStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
}
