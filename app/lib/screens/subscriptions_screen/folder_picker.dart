import 'package:flutter/material.dart';

import '../../controllers/subscription_controller.dart';
import '../../models/server_list.dart';

/// §234 — bottom-sheet выбора папки (для «Move to folder…»). Показывает все
/// папки кроме [excludeId] + пункт «New folder…» (создаёт и сразу выбирает).
/// Возвращает индекс выбранной папки в `controller.entries` или null (отмена).
Future<int?> showFolderPicker(
  BuildContext context,
  SubscriptionController controller, {
  String? excludeId,
  String title = 'Move to folder',
}) async {
  final folders = <(int, FolderServers)>[];
  for (var i = 0; i < controller.entries.length; i++) {
    final list = controller.entries[i].list;
    if (list is FolderServers && list.id != excludeId) {
      folders.add((i, list));
    }
  }

  final chosenId = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final (_, f) in folders)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(f.name),
                    subtitle: Text(
                        '${f.members.length} server${f.members.length == 1 ? '' : 's'}'),
                    onTap: () => Navigator.pop(ctx, f.id),
                  ),
                ListTile(
                  leading: const Icon(Icons.create_new_folder_outlined),
                  title: const Text('New folder…'),
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
Future<String?> showFolderNameDialog(BuildContext context,
    {String initial = '', String title = 'New folder'}) async {
  final ctl = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Folder name',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  ctl.dispose();
  return (name == null || name.isEmpty) ? null : name;
}
