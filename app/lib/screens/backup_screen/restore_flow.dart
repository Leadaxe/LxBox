import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/automation/automation_sync.dart';
import '../../services/backup_service.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/workspaces/workspace_controller.dart';
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
  // §748 — remount закрывает экраны поверх главного, и [context] уходит:
  // итог показывает корневой messenger, взятый заранее.
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);

  final BackupApplyResult apply;
  try {
    apply = await const BackupService().applyImport(
      contents,
      merge: result.merge,
      include: result.include,
    );
  } finally {
    // §748 — restore пишет хранилище мимо контроллеров главного экрана.
    // Вызывающий со своим [onApplied] перечитывает их сам; иначе сцена
    // пересоздаётся: импортированное видно сразу, а старый контроллер не
    // затрёт его первой мутацией. Remount перечитывает и язык (§279), и
    // автоматизацию (§605).
    if (onApplied == null) {
      await WorkspaceController.I.remountAfterExternalWrite();
    }
  }
  if (onApplied != null) {
    // §279 — restore мог привезти другой app_language: применить через
    // владеющий пайплайн (LocaleController), не дожидаясь рестарта.
    await LocaleController.I.reloadFromStorage();
    // §605 — бэкап мог привезти другой тумблер приёма команд и emit-гейты.
    await syncAutomationFromStorage();
    await onApplied();
  }
  // §607 — общий с главным экраном локализованный итог.
  final summary = restoreSummaryText(
    apply,
    fetchingSubscriptions: fetchingSubscriptions,
  );
  final appliedAnything = restoreAppliedAnything(apply);
  // §748 — контроллеры главного экрана уже перечитаны (remount выше или
  // [onApplied]). «Restart now» остаётся: перезапуск процесса перечитывает
  // ещё и нативную сторону.
  messenger.showSnackBar(
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
