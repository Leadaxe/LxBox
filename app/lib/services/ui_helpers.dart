import 'package:flutter/material.dart';

import 'l10n/locale_controller.dart';

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

/// §219 — единый confirm-диалог удаления (Cancel / Delete). Delete —
/// `colorScheme.error`. Был продублирован в custom_rule_edit / channel_edit /
/// dns_server_edit / routing_screen_menus. Возвращает `true` при подтверждении.
Future<bool?> showDeleteConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(getLocalText.s("Cancel")),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error),
          child: Text(confirmLabel ?? getLocalText.s("Delete")),
        ),
      ],
    ),
  );
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
        title: Text(getLocalText.s("Unsaved changes")),
        content: Text(getLocalText.s("You have unsaved changes. Save before leaving?")),
        // §045 — все TextButton + короткие надписи вмещаются в строку.
        actionsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            style: TextButton.styleFrom(foregroundColor: cs.error),
            child: Text(getLocalText.s("Discard")),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'keep'),
            child: Text(getLocalText.s("Keep")),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            style: TextButton.styleFrom(
              foregroundColor: cs.primary,
              textStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
            child: Text(getLocalText.s("Save")),
          ),
        ],
      );
    },
  );
}
