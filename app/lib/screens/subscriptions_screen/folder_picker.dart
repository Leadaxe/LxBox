import 'package:flutter/material.dart';

import '../../controllers/subscription_controller.dart';
import '../../models/server_list.dart';
import '../../services/l10n/locale_controller.dart';
import '../../widgets/app_bottom_sheet.dart';

/// §234 — bottom-sheet выбора папки (для «Move to folder…»). Показывает все
/// папки кроме [excludeId] + пункт «New folder…» (создаёт и сразу выбирает).
/// Возвращает индекс выбранной папки в `controller.entries` или null (отмена).
/// [title] == null → локализованный заголовок по умолчанию.
Future<int?> showFolderPicker(
  BuildContext context,
  SubscriptionController controller, {
  String? excludeId,
  String? title,
}) async {
  final folders = <(int, FolderServers)>[];
  for (var i = 0; i < controller.entries.length; i++) {
    final list = controller.entries[i].list;
    if (list is FolderServers && list.id != excludeId) {
      folders.add((i, list));
    }
  }

  final chosenId = await showAppBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(title ?? getLocalText.s("Move to folder"),
                style: Theme.of(ctx).textTheme.titleMedium),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final (_, f) in folders)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(f.name),
                    subtitle:
                        Text(getLocalText.plural("%d servers", f.members.length)),
                    onTap: () => Navigator.pop(ctx, f.id),
                  ),
                ListTile(
                  leading: const Icon(Icons.create_new_folder_outlined),
                  title: Text(getLocalText.s("New folder…")),
                  onTap: () => Navigator.pop(ctx, ''),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  if (chosenId == null) return null;

  if (chosenId.isEmpty) {
    // «New folder…» — спросить имя, создать, выбрать её.
    if (!context.mounted) return null;
    final name = await showFolderNameDialog(context);
    if (name == null || name.isEmpty) return null;
    await controller.addFolder(name);
    return controller.entries.length - 1;
  }

  for (var i = 0; i < controller.entries.length; i++) {
    if (controller.entries[i].id == chosenId) return i;
  }
  return null;
}

/// §234 — диалог имени папки (создание/переименование).
/// [title] == null → локализованный заголовок по умолчанию («New folder»).
Future<String?> showFolderNameDialog(BuildContext context,
    {String initial = '', String? title}) async {
  final ctl = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title ?? getLocalText.s("New folder")),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: InputDecoration(
          labelText: getLocalText.s("Folder name"),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(getLocalText.s("Cancel"))),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
          child: Text(getLocalText.s("Save")),
        ),
      ],
    ),
  );
  ctl.dispose();
  return (name == null || name.isEmpty) ? null : name;
}

/// §234 — подтверждение удаления папки: `'keep'` — вынести серверы одиночными,
/// `'all'` — удалить вместе с серверами, null — отмена. Авто-узлы роспуск не
/// переживают (см. `SubscriptionController.deleteFolderAt`): диалог их
/// называет, а папке из одних авто-узлов «Keep servers» не предлагает.
Future<String?> showDeleteFolderDialog(
    BuildContext context, FolderServers folder, String displayName) {
  final members = folder.members;
  final groups = [
    for (final m in members)
      if (m.node case final n? when n.isGroup) n.label.isNotEmpty ? n.label : n.tag,
  ];
  final summary = members.isEmpty
      ? getLocalText.s("Remove \"%s\"?", displayName)
      : getLocalText.plural(
          "Folder \"%2\$s\" contains %1\$d servers.", members.length, displayName);
  final groupsNote = groups.isEmpty
      ? null
      : getLocalText.s("Auto nodes are deleted with the folder: %s", groups.join(', '));
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(getLocalText.s("Delete folder?")),
      content: Text(groupsNote == null ? summary : '$summary\n\n$groupsNote'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(getLocalText.s("Cancel"))),
        if (members.length > groups.length)
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'keep'),
            child: Text(getLocalText.s("Keep servers")),
          ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'all'),
          style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error),
          child: Text(members.isEmpty
              ? getLocalText.s("Delete")
              : getLocalText.s("Delete folder & servers")),
        ),
      ],
    ),
  );
}
