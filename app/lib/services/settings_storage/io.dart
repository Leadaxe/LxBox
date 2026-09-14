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

/// §439 §3.1 — суффикс копии исходных байтов файла хранения, снятой первой
/// миграцией формы: `lxbox_settings.json.v0.bak`.
const _v0BakSuffix = '.v0.bak';

Future<File> _v0BakFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/${SettingsStorage._fileName}$_v0BakSuffix');
}

/// [SettingsStorage.exportV0Backup] — для
/// `GET /backup/export?include=storage&from=v0_bak`.
Future<Map<String, dynamic>?> _readV0Backup() async {
  try {
    return (await _tryReadFile(await _v0BakFile()))?.doc;
  } catch (_) {
    return null;
  }
}

/// §072 — попытаться прочитать файл как JSON Map. Возвращает `null` в
/// четырёх случаях: файл отсутствует / пустой / не Map / FormatException
/// при парсе. Все «не валидно» сводятся к одному `null` — caller сам
/// решает что делать (для main → пробовать `.bak`).
Future<Map<String, dynamic>?> _tryParseFile(File f) async =>
    (await _tryReadFile(f))?.doc;

/// Прочитанный файл хранения: исходные байты и разобранный документ.
typedef _SettingsFileRead = ({List<int> bytes, Map<String, dynamic> doc});

/// [_tryParseFile] с исходными байтами: §439 копирует их в `.v0.bak` до
/// миграции.
Future<_SettingsFileRead?> _tryReadFile(File f) async {
  if (!await f.exists()) return null;
  try {
    final bytes = await f.readAsBytes();
    if (bytes.isEmpty) return null;
    final parsed = jsonDecode(utf8.decode(bytes));
    if (parsed is Map<String, dynamic>) return (bytes: bytes, doc: parsed);
    return null;
  } catch (_) {
    return null;
  }
}

/// Чтение с диска, которое уже идёт: параллельные первые `_load()` ждут одно
/// чтение, и миграция формы (§439) не пишет файл дважды.
Future<Map<String, dynamic>>? _loadInFlight;

/// §072 — Decision tree:
///   main отсутствует   → `{storage_version: 1}` (fresh install)
///   main парсится      → return parsed
///   main битый, bak ok → recover из bak, log warning
///   main битый, bak no → `{storage_version: 1}` + sticky `_mainIsCorrupted`
///                        flag, log error. Main файл НЕ перезаписывается на
///                        этом этапе — оставляем для ручной диагностики.
///
/// §439 §3.1 — разобранный документ (main или `.bak`) проходит миграцию формы
/// до записи в `_cache`: единственная точка, через которую идут старт,
/// загрузка слота Workspaces (`clearCache` → `_load`) и тесты.
Future<Map<String, dynamic>> _load() {
  final cached = SettingsStorage._cache;
  if (cached != null) return Future.value(cached);
  return _loadInFlight ??=
      _loadFromDisk().whenComplete(() => _loadInFlight = null);
}

Future<Map<String, dynamic>> _loadFromDisk() async {
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

    // 1. Main отсутствует → fresh install. Новый документ сразу несёт версию
    //    формы: иначе первая запись легла бы без неё, и следующий старт
    //    принял бы файл этой сборки за форму 2.23.2.
    if (!await main.exists()) {
      SettingsStorage._cache = _freshDoc();
      return SettingsStorage._cache!;
    }

    // 2. Main парсится → ok.
    final mainRead = await _tryReadFile(main);
    if (mainRead != null) {
      SettingsStorage._cache =
          await _migrateOnLoad(mainRead, main: main, bak: bak);
      return SettingsStorage._cache!;
    }

    // 3. Main битый. Пробуем `.bak`.
    final bakRead = await _tryReadFile(bak);
    if (bakRead != null) {
      AppLog.I.warning(
        'SettingsStorage: main file corrupted, recovered from .bak '
        '(${main.path})',
      );
      // НЕ зовём _save() здесь — `_cache` уже консистентный, любой
      // последующий setVar пройдёт через атомарный `_save`. Если
      // процесс убьют до этого — следующий `_load` тот же recovery
      // повторит (идемпотентно). Исключение — `.bak` формы 2.23.2: миграция
      // записывает результат сразу (§439 §3.2).
      SettingsStorage._cache =
          await _migrateOnLoad(bakRead, main: main, bak: bak);
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
    SettingsStorage._cache = _freshDoc();
    return SettingsStorage._cache!;
  } catch (_) {
    // Path provider или filesystem unavailable — degrade к defaultам. Версия
    // формы нужна и здесь: запись, которая пройдёт позже, иначе легла бы
    // документом без неё, и следующий старт мигрировал бы файл этой сборки.
    SettingsStorage._cache = _freshDoc();
    return SettingsStorage._cache!;
  }
}

/// Пустой документ текущей формы.
Map<String, dynamic> _freshDoc() =>
    {kStorageVersionKey: kStorageVersion};

/// §439 §3.1 шаги 2–6 — миграция формы разобранного документа [read].
///
/// Документ текущей формы возвращается как есть без записи. Иначе: карта
/// пресетов из шаблона (ошибка шаблона миграцию не валит) → [migrateStorageDoc]
/// → копия исходных байтов в `.v0.bak` (только если её нет) → `_atomicSave`
/// нового документа → одна info-строка и потери warning'ом в AppLog.
///
/// `configDirty` не поднимается: конфиг от миграции не меняется. Если конфиг
/// до миграции был свежее настроек, его mtime выравнивается после записи (как
/// в `_save`), иначе bootstrap-сравнение §076 приняло бы миграцию за правку.
///
/// Сбой самой миграции — строка error и документ как был, без записи: лучше
/// старая форма в памяти, чем стёртые настройки.
Future<Map<String, dynamic>> _migrateOnLoad(
  _SettingsFileRead read, {
  required File main,
  required File bak,
}) async {
  final doc = read.doc;
  if (!storageDocNeedsMigration(doc)) {
    final version = storageDocVersion(doc);
    if (version != null && version > kStorageVersion) {
      AppLog.I.error(
        'SettingsStorage: storage_version $version is newer than this build '
        'knows ($kStorageVersion); the document is read as the current form, '
        'unknown top-level keys are kept',
      );
    }
    return doc;
  }

  final StorageMigrationResult result;
  try {
    result = migrateStorageDoc(
      doc,
      presetIdByDnsServerTag: await _presetIdsForMigration(),
    );
  } catch (e, st) {
    AppLog.I.error(
        'SettingsStorage: storage migration failed, the file is left as is: '
        '$e\n$st');
    return doc;
  }

  var configWasDirty = true;
  try {
    configWasDirty = await ConfigDirtyCheck.isDirty();
  } catch (_) {
    // Не знаем — mtime конфига не трогаем.
  }

  try {
    await _writeV0BakOnce(read.bytes);
  } catch (e) {
    AppLog.I.error('SettingsStorage: $_v0BakSuffix copy before the storage '
        'migration failed: $e');
  }

  try {
    await _atomicSave(result.doc, main: main, bak: bak, tmp: await _tmpFile());
    if (!configWasDirty && !SettingsStorage.configDirty) {
      await ConfigDirtyCheck.touchConfig();
    }
  } catch (e) {
    AppLog.I.error('SettingsStorage: migrated storage not written, the next '
        'start migrates again: $e');
  }

  AppLog.I.info('SettingsStorage: storage migrated to storage_version '
      '${storageDocVersion(result.doc)}'
      '${result.summary.isEmpty ? '' : ' — ${result.summary}'}');
  if (result.warnings.isNotEmpty) {
    AppLog.I.warning(
        'SettingsStorage: storage migration losses: ${result.warnings.join('; ')}');
  }
  return result.doc;
}

/// Тег preset-сервера DNS → `preset_id` по шаблону (миграция в `_load` и
/// [SettingsStorage.presetIdsForMigration]). Шаблон не загрузился — пусто:
/// preset-серверы получают `ref` = тег, дальше orphan-cleanup резолвера.
Future<Map<String, String>> _presetIdsForMigration() async {
  try {
    final template = await TemplateLoader.load();
    return presetIdsByDnsServerTag(template.selectableRules);
  } catch (e) {
    AppLog.I.warning('SettingsStorage: template not loaded for the storage '
        'migration ($e); preset DNS servers keep ref = tag');
    return const {};
  }
}

/// §439 §3.1 шаг 4 — копия исходных байтов. Существующая копия — самый первый
/// исходник, её не перетираем. tmp + rename: полуфайла копии не бывает.
Future<void> _writeV0BakOnce(List<int> bytes) async {
  final copy = await _v0BakFile();
  if (await copy.exists()) return;
  final tmp = File(
      '${copy.path}.${SettingsStorage._tmpSeq++}${SettingsStorage._tmpSuffix}');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(copy.path);
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
