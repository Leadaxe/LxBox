import 'package:flutter/material.dart';

import '../../services/backup_service.dart';
import '../../services/format_utils.dart' show formatDateTime;
import '../../services/l10n/locale_controller.dart';

class ImportDialogResult {
  const ImportDialogResult({required this.include, required this.merge});
  final Set<BackupCategory> include;
  final bool merge;
}

/// Показывает preview-диалог импорта бэкапа. Возвращает выбор пользователя
/// (категории + merge/replace) или null если отменено.
Future<ImportDialogResult?> showImportPreview(
  BuildContext context,
  BackupContents c,
) async {
  final available = c.availableCategories();
  var include = Set<BackupCategory>.from(available);
  var merge = true;
  return await showDialog<ImportDialogResult>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final servers = c.splitServerLists();
        return AlertDialog(
          title: Text(getLocalText.s("Import backup")),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (c.createdAt != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      getLocalText.s("Created: %s", formatDateTime(c.createdAt!.toLocal())),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                if (c.sourceAppVersion != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      getLocalText.s("App version: %s", '${c.sourceAppVersion}'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                Text(
                  getLocalText.s("Includes:"),
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                if (available.contains(BackupCategory.serverLists))
                  _previewCheckbox(
                    ctx,
                    label:
                        '${c.countFor(BackupCategory.serverLists)} server lists '
                        '(${servers.subs} subs, ${servers.custom} custom)',
                    checked: include.contains(BackupCategory.serverLists),
                    onChanged: (v) => set(() {
                      if (v == true) {
                        include.add(BackupCategory.serverLists);
                      } else {
                        include.remove(BackupCategory.serverLists);
                      }
                    }),
                  ),
                if (available.contains(BackupCategory.routing))
                  _previewCheckbox(
                    ctx,
                    label: 'Routing — '
                        '${c.countFor(BackupCategory.routing)} rules'
                        '${c.routingFinalOutbound != null && c.routingFinalOutbound!.isNotEmpty ? ', final: ${c.routingFinalOutbound}' : ''}',
                    checked: include.contains(BackupCategory.routing),
                    onChanged: (v) => set(() {
                      if (v == true) {
                        include.add(BackupCategory.routing);
                      } else {
                        include.remove(BackupCategory.routing);
                      }
                    }),
                  ),
                if (available.contains(BackupCategory.appSettings))
                  _previewCheckbox(
                    ctx,
                    label:
                        '${c.countFor(BackupCategory.appSettings)} app settings',
                    checked: include.contains(BackupCategory.appSettings),
                    onChanged: (v) => set(() {
                      if (v == true) {
                        include.add(BackupCategory.appSettings);
                      } else {
                        include.remove(BackupCategory.appSettings);
                      }
                    }),
                  ),
                if (available.contains(BackupCategory.vpnSettings))
                  _previewCheckbox(
                    ctx,
                    label:
                        '${c.countFor(BackupCategory.vpnSettings)} VPN system toggles',
                    checked: include.contains(BackupCategory.vpnSettings),
                    onChanged: (v) => set(() {
                      if (v == true) {
                        include.add(BackupCategory.vpnSettings);
                      } else {
                        include.remove(BackupCategory.vpnSettings);
                      }
                    }),
                  ),
                if (available.contains(BackupCategory.debugConfig))
                  _previewCheckbox(
                    ctx,
                    label: 'Debug API config (sensitive — token included)',
                    checked: include.contains(BackupCategory.debugConfig),
                    onChanged: (v) => set(() {
                      if (v == true) {
                        include.add(BackupCategory.debugConfig);
                      } else {
                        include.remove(BackupCategory.debugConfig);
                      }
                    }),
                  ),
                const SizedBox(height: 16),
                Text(
                  getLocalText.s("Mode:"),
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                RadioGroup<bool>(
                  groupValue: merge,
                  onChanged: (v) => set(() => merge = v ?? true),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RadioListTile<bool>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: true,
                        title: Text(getLocalText.s("Merge with existing (recommended)")),
                        subtitle: Text(
                          getLocalText.s("Adds new items, keeps existing."),
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      RadioListTile<bool>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: false,
                        title: Text(getLocalText.s("Replace all (destructive)")),
                        subtitle: Text(
                          getLocalText.s("Wipes existing data in selected categories."),
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(getLocalText.s("Cancel")),
            ),
            FilledButton(
              onPressed: include.isEmpty
                  ? null
                  : () async {
                      if (!merge) {
                        final ok = await showDialog<bool>(
                          context: ctx,
                          builder: (cctx) => AlertDialog(
                            title: Text(getLocalText.s("Replace all data?")),
                            content: Text(getLocalText.s("This will overwrite your current data in the selected categories. This cannot be undone.")),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(cctx, false),
                                child: Text(getLocalText.s("Cancel")),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: Theme.of(cctx)
                                      .colorScheme
                                      .errorContainer,
                                  foregroundColor: Theme.of(cctx)
                                      .colorScheme
                                      .onErrorContainer,
                                ),
                                onPressed: () => Navigator.pop(cctx, true),
                                child: Text(getLocalText.s("Replace")),
                              ),
                            ],
                          ),
                        );
                        if (ok != true) return;
                        if (!ctx.mounted) return;
                      }
                      Navigator.pop(
                        ctx,
                        ImportDialogResult(
                          include: include,
                          merge: merge,
                        ),
                      );
                    },
              child: Text(getLocalText.s("Import")),
            ),
          ],
        );
      },
    ),
  );
}

Widget _previewCheckbox(
  BuildContext ctx, {
  required String label,
  required bool checked,
  required ValueChanged<bool?> onChanged,
}) {
  return CheckboxListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
    value: checked,
    onChanged: onChanged,
    title: Text(label),
  );
}
