import '../../services/backup_service.dart';
import '../../services/l10n/locale_controller.dart';

/// §607 — итог восстановления бэкапа одной строкой: экран Backup и
/// восстановление с главного экрана показывают одно и то же (раньше — два
/// разных набора непереведённых литералов, а главный экран молчал об
/// ошибках).
///
/// [fetchingSubscriptions] — восстановление с главного экрана сразу
/// перекачивает подписки; строка говорит об этом.
String restoreSummaryText(
  BackupApplyResult apply, {
  bool fetchingSubscriptions = false,
}) {
  final parts = <String>[
    if (apply.serverListsApplied > 0)
      getLocalText.plural("%d server lists", apply.serverListsApplied),
    if (apply.routingApplied > 0)
      getLocalText.plural("routing (%d rules)", apply.routingApplied),
    if (apply.appSettingsApplied > 0)
      getLocalText.plural("%d app settings", apply.appSettingsApplied),
    if (apply.debugConfigApplied > 0) getLocalText.s("debug config"),
    if (apply.vpnSettingsApplied > 0)
      getLocalText.plural("%d VPN settings", apply.vpnSettingsApplied),
  ];
  final out = StringBuffer(
    parts.isEmpty
        ? getLocalText.s("Nothing imported")
        : getLocalText.s("Imported: %s", parts.join(', ')),
  );
  if (fetchingSubscriptions && parts.isNotEmpty) {
    out.write(' · ${getLocalText.s("fetching subscriptions…")}');
  }
  if (apply.hasErrors) {
    out.write(' · ${getLocalText.plural("%d errors", apply.errors.length)}');
  }
  // §159 — allowlist отбросил неизвестные/чужеродные ключи.
  if (apply.droppedKeys.isNotEmpty) {
    out.write(
      ' · ${getLocalText.plural("%d unknown keys skipped", apply.droppedKeys.length)}',
    );
  }
  return out.toString();
}

/// Применилась ли хоть одна категория — есть ли смысл предлагать рестарт.
bool restoreAppliedAnything(BackupApplyResult apply) =>
    apply.serverListsApplied > 0 ||
    apply.routingApplied > 0 ||
    apply.appSettingsApplied > 0 ||
    apply.debugConfigApplied > 0 ||
    apply.vpnSettingsApplied > 0;
