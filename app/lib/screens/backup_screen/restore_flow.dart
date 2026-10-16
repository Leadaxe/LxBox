import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/automation/automation_sync.dart';
import '../../services/backup_service.dart';
import '../../services/l10n/locale_controller.dart';
import '../../vpn/box_vpn_client.dart';
import 'import_preview_dialog.dart';
import 'restore_summary.dart';

/// Восстановление разобранного бэкапа: предпросмотр → применение → пост-шаги
/// → итог с «Restart now».
///
/// Один путь для файла бэкапа (экран Backup) и для настроек, принятых с
/// телефона (§622, фича 031 P4): в блоке три пост-шага от разных задач
/// (§279, §605, §607), и копия разошлась бы с первой же правкой.
///
/// [onApplied] — дополнительный шаг вызывающего после записи в хранилище
/// (главный экран перечитывает подписки); тогда [fetchingSubscriptions]
/// добавляет это в итог. Исключения применения уходят вызывающему.
Future<void> restoreFromContents(
  BuildContext context,
  BackupContents contents, {
  Future<void> Function()? onApplied,
  bool fetchingSubscriptions = false,
}) async {
  final result = await showImportPreview(context, contents);
  if (result == null) return; // cancelled

  final apply = await const BackupService().applyImport(
    contents,
    merge: result.merge,
    include: result.include,
  );
  // §279 — restore мог привезти другой app_language: применить через
  // владеющий пайплайн (LocaleController), не дожидаясь рестарта.
  await LocaleController.I.reloadFromStorage();
  // §605 — бэкап мог привезти другой тумблер приёма команд и emit-гейты.
  await syncAutomationFromStorage();
  if (onApplied != null) await onApplied();
  if (!context.mounted) return;
  // §607 — общий с главным экраном локализованный итог.
  final summary =
      restoreSummaryText(apply, fetchingSubscriptions: fetchingSubscriptions);
  final appliedAnything = restoreAppliedAnything(apply);
  // applyImport пишет в SettingsStorage, но controllers (Subscription /
  // Home / Routing screen state) держат in-memory snapshot — UI остаётся
  // stale. Restart-кнопка вызывает quitApp(); юзер сам тапает иконку,
  // app поднимается с fresh storage.
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(summary),
      duration: const Duration(seconds: 6),
      action: !appliedAnything
          ? null
          : SnackBarAction(
              label: getLocalText.s("Restart now"),
              onPressed: () => unawaited(BoxVpnClient().quitApp()),
            ),
    ),
  );
}
