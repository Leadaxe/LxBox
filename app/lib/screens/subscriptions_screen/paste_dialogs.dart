import 'package:flutter/material.dart';

import 'clipboard_analysis.dart';
import '../../services/l10n/locale_controller.dart';

/// Dialog «Unknown format» — показывает обрезанный текст clipboard'а.
/// Поведение 1:1 с прежней inline-версией в `_pasteFromClipboard`.
void showUnknownFormatDialog(BuildContext context, String text) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(getLocalText.s("Add from clipboard")),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber, color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 8),
              Text(getLocalText.s("Unknown format"),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            text.length > 100 ? '${text.substring(0, 100)}...' : text,
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: Text(getLocalText.s("OK"))),
      ],
    ),
  );
}

/// Confirm-dialog «Add from clipboard» — детект + предпросмотр. Возвращает
/// `true` если юзер нажал «Add» (поведение 1:1 с прежней inline-версией).
Future<bool?> showConfirmAddDialog(
    BuildContext context, ClipboardAnalysis analysis) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(getLocalText.s("Add from clipboard")),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(getLocalText.s("Detected: %s", analysis.title),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          if (analysis.subtitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(analysis.subtitle, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(getLocalText.s("Cancel"))),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(getLocalText.s("Add"))),
      ],
    ),
  );
}
