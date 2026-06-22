part of '../settings_storage.dart';

// Atomic load/save/recovery layer for [SettingsStorage] (§072).
//
// Вынесено `part`'ом из `settings_storage.dart` — та же библиотека, те же
// приватные статики `SettingsStorage._cache` / `_pendingSave` /
// `_mainIsCorrupted` / `_corruptionLogged`. Семантика чтения/записи/миграции
// идентична исходнику.

Future<File> _file() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/${SettingsStorage._fileName}');
}

Future<File> _bakFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/${SettingsStorage._fileName}${SettingsStorage._bakSuffix}');
}

/// §141 P1.5 — уникальный tmp на каждый вызов `_save()`. Имя:
/// `lxbox_settings.json.<seq>.tmp`. Префикс совпадает с `_orphanTmpPrefix`,
/// чтобы `_sweepOrphanTmp` мог подобрать осиротевшие после kill.
Future<File> _tmpFile() async {
  final dir = await getApplicationDocumentsDirectory();
  final seq = SettingsStorage._tmpSeq++;
  return File(
      '${dir.path}/${SettingsStorage._fileName}.$seq${SettingsStorage._tmpSuffix}');
}

/// Префикс осиротевших tmp-файлов настроек (для glob-чистки в `_load`).
const _orphanTmpPrefix = '${SettingsStorage._fileName}.';

/// §141 P1.5 — удалить осиротевшие `lxbox_settings.json.<seq>.tmp` (kill между
/// write и rename). Best-effort: фейл listing/delete не критичен. НЕ трогает
/// main (`lxbox_settings.json`) и `.bak` (`...json.bak` не кончается на `.tmp`).
Future<void> _sweepOrphanTmp() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith(_orphanTmpPrefix) &&
          name.endsWith(SettingsStorage._tmpSuffix)) {
        try {
          await entity.delete();
        } catch (_) {
          // ignore — не критично
        }
      }
    }
  } catch (_) {
    // listing недоступен (path provider в тестах и т.п.) — пропускаем
  }
}

/// §072 — попытаться прочитать файл как JSON Map. Возвращает `null` в
/// четырёх случаях: файл отсутствует / пустой / не Map / FormatException
/// при парсе. Все «не валидно» сводятся к одному `null` — caller сам
/// решает что делать (для main → пробовать `.bak`).
Future<Map<String, dynamic>?> _tryParseFile(File f) async {
  if (!await f.exists()) return null;
  try {
    final raw = await f.readAsString();
    if (raw.isEmpty) return null;
    final parsed = jsonDecode(raw);
    if (parsed is Map<String, dynamic>) return parsed;
    return null;
  } catch (_) {
    return null;
  }
}

/// §072 — Decision tree:
///   main отсутствует   → `{}` (fresh install)
///   main парсится      → return parsed
///   main битый, bak ok → recover из bak, log warning
///   main битый, bak no → `{}` + sticky `_mainIsCorrupted` flag, log error.
///                        Main файл НЕ перезаписывается на этом этапе —
///                        оставляем для ручной диагностики.
Future<Map<String, dynamic>> _load() async {
  if (SettingsStorage._cache != null) return SettingsStorage._cache!;
  // Wait for any pending save to complete before loading
  if (SettingsStorage._pendingSave != null) await SettingsStorage._pendingSave;

  // Если path provider недоступен (binding не инициализирован в тестах,
  // platform unsupported и т.п.) — degrade к `{}`. Это сохраняет
  // legacy-семантику оригинального `_load` (try-catch вокруг всего тела).
  try {
    final main = await _file();
    final bak = await _bakFile();

    // Best-effort: убираем осиротевшие `.tmp` от прошлых оборванных `_save()`.
    // Rename консумирует `.tmp` при success — оставшийся файл значит save был
    // убит. Содержимое не консистентно (partial write), нельзя использовать
    // для recovery. §141 P1.5 — tmp теперь уникальны per-save
    // (`lxbox_settings.json.<seq>.tmp`), поэтому чистим по маске, а не один
    // фиксированный файл.
    await _sweepOrphanTmp();

    // 1. Main отсутствует → fresh install.
    if (!await main.exists()) {
      SettingsStorage._cache = {};
      return SettingsStorage._cache!;
    }

    // 2. Main парсится → ok.
    final mainParsed = await _tryParseFile(main);
    if (mainParsed != null) {
      SettingsStorage._cache = mainParsed;
      return SettingsStorage._cache!;
    }

    // 3. Main битый. Пробуем `.bak`.
    final bakParsed = await _tryParseFile(bak);
    if (bakParsed != null) {
      AppLog.I.warning(
        'SettingsStorage: main file corrupted, recovered from .bak '
        '(${main.path})',
      );
      SettingsStorage._cache = bakParsed;
      // НЕ зовём _save() здесь — `_cache` уже консистентный, любой
      // последующий setVar пройдёт через атомарный `_save`. Если
      // процесс убьют до этого — следующий `_load` тот же recovery
      // повторит (идемпотентно).
      return SettingsStorage._cache!;
    }

    // 4. Main битый, bak не помог → drop с sticky flag.
    SettingsStorage._mainIsCorrupted = true;
    if (!SettingsStorage._corruptionLogged) {
      SettingsStorage._corruptionLogged = true;
      AppLog.I.error(
        'SettingsStorage: main file corrupted, no recoverable .bak. '
        'Settings reset to defaults; main file left on disk for diagnostics '
        '(${main.path})',
      );
    }
    SettingsStorage._cache = {};
    return SettingsStorage._cache!;
  } catch (_) {
    // Path provider или filesystem unavailable — degrade к defaultам.
    SettingsStorage._cache = {};
    return SettingsStorage._cache!;
  }
}

/// §072 — атомарная запись:
///   1. Copy валидного main → `.bak` (если main существует и валиден).
///   2. Write новых данных в `.tmp` с `flush: true`.
///   3. `tmp.rename(main)` — POSIX rename(2), атомарный в пределах одной
///      FS. `getApplicationDocumentsDirectory()` это всегда app-internal
///      storage (ext4/f2fs) → single mount → safe.
///
/// Если kill попадёт:
///   • между copy и tmp-write → main целый, .bak старый. Потерь нет.
///   • между tmp-write и rename → main целый, .bak старый. Новые данные
///     потеряны, но старые сохранены. Acceptable.
///   • во время rename — это atomic syscall, либо main old либо main new.
Future<void> _save() async {
  // §159 — хардкод-очистка «мёртвых» ключей (node_overrides /
  // show_detour_servers / vars.auto_rebuild) удалена. Единственная машинерия
  // чистки мусора — allowlist на ВХОДЕ (`replaceRaw`): неизвестный ключ туда не
  // попадает. Уже лежащий на диске мусор безвреден (никем не читается) и уйдёт
  // при первом же импорте бэкапа.
  final data = Map<String, dynamic>.from(SettingsStorage._cache ?? {});

  final main = await _file();
  final bak = await _bakFile();
  final tmp = await _tmpFile();

  SettingsStorage._pendingSave =
      _atomicSave(data, main: main, bak: bak, tmp: tmp);
  await SettingsStorage._pendingSave;
  SettingsStorage._pendingSave = null;

  // §113 — настройки записаны; если конфиг НЕ помечен грязным, выровнять его
  // mtime, чтобы bootstrap mtime-compare не дал ложного «config changed»
  // после kill. dirty=true (свёрнут посреди config-правки, пересборки ещё не
  // было) → не трогаем: конфиг честно устарел, следующий старт пересоберёт.
  if (!SettingsStorage.configDirty) {
    await ConfigDirtyCheck.touchConfig();
  }
}

Future<void> _atomicSave(
  Map<String, dynamic> data, {
  required File main,
  required File bak,
  required File tmp,
}) async {
  final encoded = const JsonEncoder.withIndent('  ').convert(data);

  // 1. Snapshot текущий **валидный** main → .bak. Битый main не копируем —
  //    нет смысла плодить второй битый файл, лучше оставить старый .bak
  //    если он был (он от ещё более раннего, но валидного состояния).
  if (await main.exists()) {
    final mainParsed = await _tryParseFile(main);
    if (mainParsed != null) {
      try {
        await main.copy(bak.path);
      } catch (_) {
        // best-effort — не блокируем save если copy не получился
        // (acceptable: новые данные всё равно перезапишут main атомарно).
      }
    }
  }

  // 2. Write в tmp с flush. Без flush rename может зафиксировать pointer
  //    на ещё не сброшенные dirty pages → видимо как пустой/обрезанный
  //    файл при kill сразу после rename.
  await tmp.writeAsString(encoded, flush: true);

  // 3. Атомарная замена.
  await tmp.rename(main.path);

  // 4. Main теперь свежий и валидный — сбрасываем sticky-флаги.
  //    Следующий `_load()` (после `resetCacheForTesting` или рестарта
  //    процесса) увидит чистый main и не пойдёт через corruption path.
  SettingsStorage._mainIsCorrupted = false;
  SettingsStorage._corruptionLogged = false;
}
