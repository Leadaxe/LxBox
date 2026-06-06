import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// §076 — Bootstrap mtime compare: settings_file.mtime > config_file.mtime
/// → settings новее → config устарел → configDirty = true.
///
/// Используется на app launch (`SubscriptionController.init` или
/// `home_screen._initSubsAndAutoUpdate`) чтобы восстановить in-memory
/// `configDirty` после kill mid-session.
///
/// `configDirty` сам **не persisted** — derive'ится из file mtime
/// comparison. См. spec docs/spec/features/076 settings-and-config-lifecycle.
///
/// File paths:
///   - lxbox_settings.json: `getApplicationDocumentsDirectory()` (path_provider)
///   - singbox_config.json: тот же dir, имя из native ConfigManager.kt:12
///     (`CONFIG_FILE = "singbox_config.json"`). Path consistent потому что
///     native использует `Context.filesDir()` == `getApplicationDocumentsDirectory()`
///     на Android.
class ConfigDirtyCheck {
  static const _settingsFileName = 'lxbox_settings.json';
  static const _singboxConfigFileName = 'singbox_config.json';

  /// Returns mtime of `lxbox_settings.json`. `null` если файл не существует
  /// (fresh install).
  static Future<DateTime?> settingsModifiedTime() async {
    return _mtimeOf(_settingsFileName);
  }

  /// Returns mtime of `singbox_config.json`. `null` если файл не существует
  /// (fresh install — VPN ещё ни разу не start'ался).
  static Future<DateTime?> configModifiedTime() async {
    return _mtimeOf(_singboxConfigFileName);
  }

  /// True если settings file новее config file (или config отсутствует).
  /// Это означает что есть pending changes в settings которые ещё не
  /// запеклись в saved config. См. spec §076 «Bootstrap on app launch».
  ///
  /// Edge cases:
  ///   - both absent → false (fresh install, ничего пересобирать; existing
  ///     bootstrap path через `configRaw.isEmpty` подхватит когда entries появятся)
  ///   - only settings absent → false (странный edge case — config есть, settings
  ///     нет; не наш сценарий, treat as clean)
  ///   - only config absent → true (settings есть, config надо собрать)
  ///   - settings mtime > config mtime → true
  ///   - settings mtime <= config mtime → false (config свежее или equal)
  static Future<bool> isDirty() async {
    final s = await settingsModifiedTime();
    final c = await configModifiedTime();
    if (s == null) return false; // fresh install / no settings
    if (c == null) return true; // settings есть, config нет
    return s.isAfter(c);
  }

  static Future<DateTime?> _mtimeOf(String fileName) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$fileName');
      if (!await f.exists()) return null;
      final stat = await f.stat();
      return stat.modified;
    } catch (_) {
      // path_provider unavailable / IO error → treat as null (clean state).
      return null;
    }
  }
}
