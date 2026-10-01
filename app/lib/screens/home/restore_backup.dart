import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../controllers/subscription_controller.dart';
import '../../services/app_log.dart';
import '../../services/automation/automation_sync.dart';
import '../../services/backup_service.dart';
import '../../services/error_format.dart';
import '../../services/subscription/auto_updater.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/file_import.dart';
import '../backup_screen/restore_summary.dart';

/// Empty-state quick-restore flow.
///
/// Open SAF file picker → parse backup file → `applyImport(merge: false,
/// include: all)` → snackbar + restart hint. Без preview dialog'а (юзер в
/// empty state, явно хочет restore целиком — никаких категорий снимать не
/// надо). Polished restore через `Settings → Backup` остаётся для merge-flow
/// и selective import'а.
Future<void> restoreFromBackup(
  BuildContext context,
  SubscriptionController subController,
  AutoUpdater autoUpdater,
) async {
  try {
    // §372 — Android TV без DocumentsUI: подсказка вместо тихого выхода.
    final outcome = await pickFileSafely(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (outcome is! PickedFiles) {
      final problem = pickProblemText(outcome);
      if (problem != null && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(problem)));
      }
      return;
    }
    final file = outcome.single;
    String? raw;
    try {
      raw = const Utf8Decoder(allowMalformed: false).convert(file.bytes);
    } catch (e) {
      AppLog.I.warning('[restore] backup bytes not valid UTF-8: $e');
    }
    if (raw == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(getLocalText.s("Could not read file."))),
        );
      }
      return;
    }

    const service = BackupService();
    final BackupContents contents;
    try {
      contents = await service.parseImport(raw);
    } on FormatException catch (e) {
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(getLocalText.s("Invalid backup")),
          content: Text(e.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(getLocalText.s("OK")),
            ),
          ],
        ),
      );
      return;
    }

    final include = contents.availableCategories();
    final apply = await service.applyImport(
      contents,
      merge: false,
      include: include,
    );
    // §605 — бэкап мог привезти другой тумблер приёма команд и emit-гейты.
    await syncAutomationFromStorage();
    // §279/§607 — restore мог привезти другой app_language: применить через
    // владеющий пайплайн, как экран Backup.
    await LocaleController.I.reloadFromStorage();
    if (!context.mounted) return;

    // Re-read storage в in-memory state controller'ов: `applyImport` записал
    // в storage, но `subController` всё ещё хранит entries времени init'а
    // (когда server_lists был пуст). Без `init()` повтор юзер увидит «нет
    // серверов» пока не перезапустит app.
    await subController.init();
    // Backup хранит только URL/name/meta подписок — nodes re-fetch'аются.
    // Triggers fetch немедленно (manual + force обходит auto_update_subs
    // toggle и min-retry cooldown).
    unawaited(
        autoUpdater.maybeUpdateAll(UpdateTrigger.manual, force: true));

    // §607 — тот же локализованный итог, что на экране Backup, с ошибками.
    final summary =
        restoreSummaryText(apply, fetchingSubscriptions: true);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(summary),
        duration: const Duration(seconds: 6),
      ),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(getLocalText.s(
                "Restore failed: %s", formatUserError(e).render()))),
      );
    }
  }
}
