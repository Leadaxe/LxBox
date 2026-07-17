import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/subscription_controller.dart';
import '../../models/server_list.dart';
import '../../models/ui_msg.dart';
import '../../services/l10n/l10n.dart';
import '../../services/subscription/auto_updater.dart';
import '../../services/subscription/input_helpers.dart';
import 'folder_picker.dart';

/// Long-press bottom-sheet для записи подписки/сервера. Поведение 1:1 с
/// прежним `_showContextMenu` — копировать URL, share, update,
/// reset fail-count, delete-with-confirm. §234 — у папки своё меню
/// (rename/delete), у одиночного сервера + «Move to folder…».
void showEntryContextMenu(
  BuildContext context,
  int index,
  SubscriptionEntry entry, {
  required SubscriptionController subController,
  required AutoUpdater autoUpdater,
  required Future<void> Function(SubscriptionEntry entry) onShareUrl,
}) {
  if (entry.list is FolderServers) {
    _showFolderContextMenu(context, index, entry, subController);
    return;
  }
  showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy),
            title: Text(ctx.l.subCopyUrl),
            onTap: () {
              final url = entry.url.isNotEmpty
                  ? entry.url
                  : entry.connections.isNotEmpty
                      ? entry.connections.first
                      : '';
              if (url.isNotEmpty) {
                Clipboard.setData(ClipboardData(text: url));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(ctx.l.subUrlCopied)),
                );
              }
              Navigator.pop(ctx);
            },
          ),
          // Share (night T6-2): for SubscriptionServers с URL даём masked-
          // share по умолчанию. Юзер может включить "Share with token"
          // через confirm-dialog (с предупреждением).
          if (entry.url.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: Text(ctx.l.subShareUrlMenu),
              onTap: () async {
                Navigator.pop(ctx);
                await onShareUrl(entry);
              },
            ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: Text(ctx.l.subMenuUpdate),
            onTap: () {
              Navigator.pop(ctx);
              unawaited(subController.updateAt(index));
            },
          ),
          // §129 — сменить источник подписки (online URL ↔ локальный файл).
          // Транзакционно: старый источник сбрасывается только после успеха
          // нового (см. updateSourceAt). Для file-подписки это ещё и «обновить»
          // (выбрать файл заново).
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(ctx.l.subEditSourceMenu),
            onTap: () async {
              Navigator.pop(ctx);
              await showEditSourceDialog(context, index, entry, subController);
            },
          ),
          // Reset fail-count (night T8-1). Если провайдер вернулся в строй
          // после фриза (5 фейлов подряд → заморожено до app-restart),
          // юзер может руками разморозить без перезапуска.
          if (entry.url.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: Text(ctx.l.subResetFailMenu),
              onTap: () async {
                Navigator.pop(ctx);
                autoUpdater.resetFailCount(entry.url);
                await subController.updateAt(index);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.l.subResetFailSnack)),
                );
              },
            ),
          // §234 — одиночный сервер можно перенести в папку (личные
          // prefix/detour при этом заменяются папочными).
          if (entry.list is UserServer)
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: Text(ctx.l.subMoveToFolderMenu),
              onTap: () async {
                Navigator.pop(ctx);
                final folderIndex =
                    await showFolderPicker(context, subController);
                if (folderIndex == null || !context.mounted) return;
                // Индекс сервера по ссылке — создание новой папки в пикере
                // добавляет entry, а reorder мог сместить исходный index.
                final serverIndex = subController.entries.indexOf(entry);
                if (serverIndex < 0) return;
                final err = await subController.moveServerToFolder(
                    serverIndex, folderIndex);
                if (err != null && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(err.render(context.l))));
                }
              },
            ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
            title: Text(ctx.l.commonDelete, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () async {
              Navigator.pop(ctx);
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (dCtx) => AlertDialog(
                  title: Text(dCtx.l.subDeleteSubscriptionTitle),
                  content: Text(dCtx.l.subDeleteRemoveBody(entry.displayName)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(dCtx, false), child: Text(dCtx.l.commonCancel)),
                    TextButton(
                      onPressed: () => Navigator.pop(dCtx, true),
                      style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                      child: Text(dCtx.l.commonDelete),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await subController.removeAt(index);
                          }
            },
          ),
        ],
      ),
    ),
  );
}

/// §234 — long-press меню папки: rename / delete (с выбором судьбы серверов).
void _showFolderContextMenu(
  BuildContext context,
  int index,
  SubscriptionEntry entry,
  SubscriptionController subController,
) {
  final folder = entry.list as FolderServers;
  showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(ctx.l.subRenameMenu),
            onTap: () async {
              Navigator.pop(ctx);
              if (!context.mounted) return;
              final name = await showFolderNameDialog(context,
                  initial: entry.name, title: context.l.subRenameFolderTitle);
              if (name == null) return;
              await subController.renameAt(index, name);
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_outline,
                color: Theme.of(context).colorScheme.error),
            title: Text(ctx.l.subDeleteFolderMenu,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () async {
              Navigator.pop(ctx);
              final choice = await showDialog<String>(
                context: context,
                builder: (dCtx) => AlertDialog(
                  title: Text(dCtx.l.subDeleteFolderTitle),
                  content: Text(folder.members.isEmpty
                      ? dCtx.l.subDeleteRemoveBody(entry.displayName)
                      : dCtx.l.subDeleteFolderBody(
                          folder.members.length, entry.displayName)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dCtx),
                        child: Text(dCtx.l.commonCancel)),
                    if (folder.members.isNotEmpty)
                      TextButton(
                        onPressed: () => Navigator.pop(dCtx, 'keep'),
                        child: Text(dCtx.l.subKeepServers),
                      ),
                    TextButton(
                      onPressed: () => Navigator.pop(dCtx, 'all'),
                      style: TextButton.styleFrom(
                          foregroundColor:
                              Theme.of(dCtx).colorScheme.error),
                      child: Text(folder.members.isEmpty
                          ? dCtx.l.commonDelete
                          : dCtx.l.subDeleteFolderAndServers),
                    ),
                  ],
                ),
              );
              if (choice == null) return;
              await subController.deleteFolderAt(index,
                  keepServers: choice == 'keep');
            },
          ),
        ],
      ),
    ),
  );
}

/// §129 — диалог смены источника подписки: online URL ↔ локальный файл.
/// Переключатель режима; online → текст-поле URL, file → picker. Save зовёт
/// `updateSourceAt` (транзакционно: старый источник живёт, пока новый не удался).
Future<void> showEditSourceDialog(
  BuildContext context,
  int index,
  SubscriptionEntry entry,
  SubscriptionController subController,
) async {
  final wasFile = isFileSubscription(entry.url);
  var fileMode = wasFile;
  final urlCtl = TextEditingController(text: wasFile ? '' : entry.url);
  String? pickedBody; // тело выбранного файла (file-режим)
  String pickedName = wasFile ? entry.displayName : '';
  var busy = false;

  await showDialog<void>(
    context: context,
    builder: (dCtx) => StatefulBuilder(
      builder: (dCtx, setLocal) => AlertDialog(
        title: Text(dCtx.l.subEditSourceTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadioGroup<bool>(
              groupValue: fileMode,
              onChanged: (v) => setLocal(() => fileMode = v ?? false),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<bool>(
                    value: false,
                    title: Text(dCtx.l.subSourceOnlineUrl),
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<bool>(
                    value: true,
                    title: Text(dCtx.l.subSourceLocalFile),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (!fileMode)
              TextField(
                controller: urlCtl,
                decoration: InputDecoration(
                  labelText: dCtx.l.subSubscriptionUrlLabel,
                  // l10n-exempt: URL scheme hint, locale-invariant
                  hintText: 'https://…',
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Text(
                      pickedBody == null
                          ? (pickedName.isEmpty
                              ? dCtx.l.subNoFileChosen
                              : pickedName)
                          : pickedName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final res = await FilePicker.pickFiles(
                          withData: true, allowMultiple: false);
                      if (res == null || res.files.isEmpty) return;
                      final f = res.files.single;
                      String text;
                      if (f.bytes != null && f.bytes!.isNotEmpty) {
                        text = String.fromCharCodes(f.bytes!);
                      } else if (f.path != null) {
                        text = await File(f.path!).readAsString();
                      } else {
                        return;
                      }
                      setLocal(() {
                        pickedBody = text;
                        pickedName = f.name;
                      });
                    },
                    child: Text(dCtx.l.subChooseFile),
                  ),
                ],
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(dCtx),
            child: Text(dCtx.l.commonCancel),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setLocal(() => busy = true);
                    UiMsg? err;
                    if (fileMode) {
                      if (pickedBody == null) {
                        // file-режим без нового файла: если и было file — просто
                        // переоткрыть текущий кэш нельзя, требуем выбор.
                        setLocal(() => busy = false);
                        ScaffoldMessenger.of(dCtx).showSnackBar(
                          SnackBar(content: Text(dCtx.l.subChooseFileFirst)),
                        );
                        return;
                      }
                      // file: контроллер сам сгенерит свежий file:<uuid>.
                      err = await subController.updateSourceAt(
                        index,
                        fileBody: pickedBody,
                      );
                    } else {
                      final url = urlCtl.text.trim();
                      if (!isSubscriptionUrl(url)) {
                        setLocal(() => busy = false);
                        ScaffoldMessenger.of(dCtx).showSnackBar(
                          SnackBar(content: Text(dCtx.l.subEnterValidUrl)),
                        );
                        return;
                      }
                      err = await subController.updateSourceAt(index,
                          httpUrl: url);
                    }
                    if (!dCtx.mounted) return;
                    if (err == null) {
                      Navigator.pop(dCtx);
                    } else {
                      setLocal(() => busy = false);
                      ScaffoldMessenger.of(dCtx).showSnackBar(
                          SnackBar(content: Text(err.render(dCtx.l))));
                    }
                  },
            child: busy
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(dCtx.l.commonSave),
          ),
        ],
      ),
    ),
  );
  urlCtl.dispose();
}
