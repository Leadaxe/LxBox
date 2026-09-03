import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../vpn/box_vpn_client.dart';

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
/// File paths — ДВА разных каталога (§414):
///   - lxbox_settings.json: `getApplicationDocumentsDirectory()` (path_provider);
///     на Android это `Context.getDir("flutter")` = `app_flutter/`.
///   - singbox_config.json: native `Context.filesDir` = `files/` — туда пишет
///     `ConfigManager.kt` (`CONFIG_FILE = "singbox_config.json"`). Путь берём
///     через `BoxVpnClient.getFilesDir()` (§316), как диагностика ядра.
///     Пока конфиг искали в Documents, файл «не существовал» на каждом
///     запуске → `isDirty()` всегда true, `touchConfig()` — no-op.
class ConfigDirtyCheck {
  static const _settingsFileName = 'lxbox_settings.json';
  static const _singboxConfigFileName = 'singbox_config.json';

  /// Native `filesDir`, резолвится через MethodChannel один раз за процесс.
  /// Кэшируется только успешный ответ: без канала (юнит-тесты) каждый вызов
  /// падает на Dart-путь, и тест, поднявший мок позже, его получит.
  static String? _filesDirCache;

  /// Каталог, где лежит `singbox_config.json`: native `filesDir`, а при
  /// недоступности канала — Documents (там же, где настройки; юнит-тесты
  /// кладут конфиг рядом с настройками).
  static Future<Directory> _configDir() async {
    final cached = _filesDirCache;
    if (cached != null) return Directory(cached);
    final native = await BoxVpnClient().getFilesDir();
    if (native != null && native.isNotEmpty) {
      _filesDirCache = native;
      return Directory(native);
    }
    return getApplicationDocumentsDirectory();
  }

  /// Сброс кэша `filesDir` между тестами (мок канала меняется от теста к
  /// тесту, а кэш — статик процесса).
  static void resetForTesting() {
    _filesDirCache = null;
  }

  /// Returns mtime of `lxbox_settings.json`. `null` если файл не существует
  /// (fresh install).
  static Future<DateTime?> settingsModifiedTime() async {
    return _mtimeOf(getApplicationDocumentsDirectory(), _settingsFileName);
  }

  /// Returns mtime of `singbox_config.json`. `null` если файл не существует
  /// (fresh install — VPN ещё ни разу не start'ался).
  static Future<DateTime?> configModifiedTime() async {
    return _mtimeOf(_configDir(), _singboxConfigFileName);
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
    // §113 — сравнение с СЕКУНДНОЙ резолюцией. `setLastModified`
    // (touchConfig после чистой записи) усекает mtime до целой секунды, а
    // `stat().modified` натуральной записи настроек хранит суб-секунду —
    // прямой `isAfter` ловил бы эту разницу как ложное «грязно». Флор обоих
    // до секунды: правка в одной секунде с последней чистой записью → equal
    // → чисто; реальное изменение (≥ следующая секунда) → грязно.
    return _floorToSecond(s).isAfter(_floorToSecond(c));
  }

  static DateTime _floorToSecond(DateTime t) =>
      DateTime.fromMillisecondsSinceEpoch(
          (t.millisecondsSinceEpoch ~/ 1000) * 1000,
          isUtc: t.isUtc);

  static Future<DateTime?> _mtimeOf(
      Future<Directory> dir, String fileName) async {
    try {
      final f = File('${(await dir).path}/$fileName');
      if (!await f.exists()) return null;
      final stat = await f.stat();
      return stat.modified;
    } catch (_) {
      // path_provider unavailable / IO error → treat as null (clean state).
      return null;
    }
  }

  /// §113 — выровнять mtime config-файла **к mtime файла настроек**, чтобы
  /// bootstrap mtime-compare ([isDirty], строгий `isAfter`) не дал ложного
  /// «грязно». Зовётся из `SettingsStorage._save()` после записи настроек,
  /// когда `configDirty` снят (конфиг уже в синхроне — либо пересобран, либо
  /// правка была не config-значимой).
  ///
  /// Важно: выравниваем именно к mtime настроек, **не** к `now()`.
  /// `FileStat.modified` имеет секундную резолюцию — `now()` после записи
  /// попадает в ту же секунду, но граница округления плавает и может дать
  /// `config < settings`. Точное равенство → `isAfter` = false, а следующая
  /// грязная запись (без touch) честно уходит вперёд.
  ///
  /// No-op если config-файла ещё нет (VPN ни разу не стартовал → `isDirty`
  /// честно вернёт true) или файла настроек нет. Не throws.
  static Future<void> touchConfig() async {
    try {
      final settingsMtime = await settingsModifiedTime();
      if (settingsMtime == null) return;
      final dir = await _configDir();
      final f = File('${dir.path}/$_singboxConfigFileName');
      if (await f.exists()) {
        await f.setLastModified(settingsMtime);
      }
    } catch (_) {
      // path_provider / IO error — touch best-effort, не критично.
    }
  }
}
