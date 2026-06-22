import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../controllers/subscription_controller.dart';
import '../../services/app_log.dart';
import '../../services/backup_service.dart';
import '../../services/error_format.dart';
import '../../services/subscription/auto_updater.dart';

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
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    String? raw;
    if (file.bytes != null) {
      try {
        raw = const Utf8Decoder(allowMalformed: false).convert(file.bytes!);
      } catch (e) {
        AppLog.I.warning('[restore] backup bytes not valid UTF-8: $e');
      }
    } else if (file.path != null) {
      raw = await File(file.path!).readAsString();
    }
    if (raw == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read file.')),
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
          title: const Text('Invalid backup'),
          content: Text(e.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
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

    final parts = <String>[];
    if (apply.serverListsApplied > 0) {
      parts.add('${apply.serverListsApplied} server lists');
    }
    if (apply.routingApplied > 0) parts.add('${apply.routingApplied} rules');
    if (apply.appSettingsApplied > 0) {
      parts.add('${apply.appSettingsApplied} app settings');
    }
    if (apply.debugConfigApplied > 0) parts.add('debug config');
    if (apply.vpnSettingsApplied > 0) {
      parts.add('${apply.vpnSettingsApplied} VPN settings');
    }
    final summary = parts.isEmpty
        ? 'Imported nothing'
        : 'Imported: ${parts.join(', ')} · fetching subscriptions…';
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
        SnackBar(content: Text('Restore failed: ${formatUserError(e)}')),
      );
    }
  }
}
