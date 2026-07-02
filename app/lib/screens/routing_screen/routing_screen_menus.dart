import 'package:flutter/material.dart';

import '../../models/custom_rule.dart';
import '../../services/ui_helpers.dart';

/// Popup-меню экрана Routing. Чистая презентация: показывают `showMenu` /
/// `showDialog` и возвращают выбор. Вся state-мутация остаётся в экране.

/// Long-press меню у ☁ для preset-rule: Refresh / Clear. Возвращает
/// `'refresh'`, `'clear'` или null (dismiss). `pos` — глобальные координаты
/// точки long-press.
Future<String?> showPresetCloudMenu(
  BuildContext context,
  Offset pos,
) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  return showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(
      pos.dx,
      pos.dy,
      overlay.size.width - pos.dx,
      overlay.size.height - pos.dy,
    ),
    items: [
      const PopupMenuItem<String>(
        value: 'refresh',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.refresh, size: 20),
          title: Text('Refresh rule-sets'),
        ),
      ),
      PopupMenuItem<String>(
        value: 'clear',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.cloud_off_outlined,
              size: 20, color: Theme.of(context).colorScheme.error),
          title: Text('Clear cached files',
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      ),
    ],
  );
}

/// Контекстное меню по long-press на tile — только Delete. Возвращает
/// `'delete'` или null. `pos` — глобальные координаты точки long-press.
Future<String?> showRuleContextMenu(
  BuildContext context,
  Offset pos,
) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  return showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(
      pos.dx,
      pos.dy,
      overlay.size.width - pos.dx,
      overlay.size.height - pos.dy,
    ),
    items: [
      PopupMenuItem<String>(
        value: 'delete',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.delete_outline,
              size: 20, color: Theme.of(context).colorScheme.error),
          title: Text('Delete',
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      ),
    ],
  );
}

/// Confirm-dialog удаления custom-rule. §219 — тонкая обёртка над общим
/// showDeleteConfirmDialog (ui_helpers). Возвращает true если юзер подтвердил.
Future<bool?> showDeleteCustomRuleDialog(
  BuildContext context,
  CustomRule rule,
) {
  return showDeleteConfirmDialog(
    context,
    title: 'Delete rule?',
    message: 'Remove "${rule.name}" permanently?',
  );
}
