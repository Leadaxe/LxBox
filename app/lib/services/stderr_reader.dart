import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../vpn/box_vpn_client.dart';

/// §316 — базовое имя краш-репорта ядра. Совпадает с `crashReportSource`
/// из `BoxApplication` (`SetupOptions.crashReportSource = "lxbox"`): libbox
/// редиректит Go-stderr в `workingPath/CrashReport-<source>.log`.
///
/// Дублирует константу из `debug/handlers/files.dart` намеренно НЕ будем —
/// см. импорт ниже.
const kCrashReportBaseName = 'CrashReport-lxbox.log';

/// §316 — подпапка, куда ЯДРО архивирует прошлые репорты на каждом `Setup()`.
/// Размер архива ядро не ограничивает — ротацию делаем мы ([CrashReports.prune]).
const kCrashArchiveDir = 'crash_reports';

/// §316 — файл Go-трейса внутри каталога архивного репорта. Ядро кладёт
/// каждое падение отдельным каталогом `crash_reports/<ISO-таймстамп>/`, а не
/// одним файлом: `go.log` + `metadata.json` + `configuration.json`.
const kCrashTraceName = 'go.log';

/// §316 — метаданные репорта (`source`, `coreVersion`, `goVersion`,
/// `crashedAt`) рядом с трейсом.
const kCrashMetaName = 'metadata.json';

/// §316 — сколько архивных репортов держим.
const kCrashKeep = 10;

/// Один краш-репорт: файл трейса + метаданные для списка.
///
/// **Архивный репорт — это КАТАЛОГ, а не файл.** Ядро складывает каждое
/// падение в `crash_reports/<ISO-таймстамп>/` из трёх файлов:
/// `go.log` (сам трейс), `metadata.json` (версия ядра, Go, время краха),
/// `configuration.json` (конфиг на момент падения). [path] указывает на
/// `go.log` — это то, что отдаём пользователю; [size] — его размер.
class CrashReportFile {
  const CrashReportFile({
    required this.path,
    required this.name,
    required this.mtime,
    required this.size,
    required this.isCurrent,
    this.dirPath,
    this.coreVersion,
  });

  /// Путь к файлу трейса (`go.log` для архивного, сам репорт для текущего).
  final String path;

  /// Имя для показа/share: таймстамп-каталог у архивного, имя файла у текущего.
  final String name;
  final DateTime mtime;
  final int size;

  /// Текущий (ещё не архивированный ядром) репорт активной сессии.
  final bool isCurrent;

  /// Каталог архивного репорта (`null` у текущего) — нужен, чтобы отдать
  /// весь пакет целиком, а не только трейс.
  final String? dirPath;

  /// Версия ядра из `metadata.json` — сразу видно, на какой сборке упало.
  final String? coreVersion;
}

/// §038/§316 — read-only доступ к Go-паникам ядра.
///
/// Libbox через `debug.SetCrashOutput` (`experimental/libbox/setup.go`)
/// перенаправляет Go stderr в `workingPath/CrashReport-lxbox.log`. При
/// panic'е без recover() Go runtime пишет multi-goroutine stacktrace до
/// SIGABRT'а — файл переживает смерть процесса. Прошлые репорты ядро
/// само перекладывает в `crash_reports/` при следующем `Setup()`.
///
/// **Читаем `CrashReport-lxbox.log`, а не `stderr.log`.** Второе — имя из
/// схемы ДО libbox 1.14, когда `redirectStderr` звался вручную; на 1.14
/// такого файла не существует, и §038-канал молча отдавал пустоту.
/// Фоллбэка на старое имя нет намеренно (решение юзера): тянуть мёртвое
/// имя ради теоретических старых установок — мусор.
class StderrReader {
  /// Содержимое текущего репорта или `null` если файл отсутствует/пуст.
  static Future<String?> read() async {
    final file = await _file();
    if (file == null) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// Путь к текущему репорту для Share — `null` если отсутствует/пуст.
  static Future<String?> path() async => (await _file())?.path;

  /// Текущий репорт как [File], только если он существует И непуст.
  /// Пустой файл — норма: ядро пересоздаёт его (`os.Create`) на каждом
  /// `Setup()`, так что 0 байт означает «паник не было».
  static Future<File?> _file() async {
    try {
      final base = await CrashReports.baseDir();
      final f = File('$base/$kCrashReportBaseName');
      if (await f.exists() && await f.length() > 0) return f;
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// §316 — история краш-репортов ядра: список, ротация, «показывали ли уже».
class CrashReports {
  /// Native `Context.filesDir` — место, куда пишет ЯДРО.
  ///
  /// ВАЖНО: это НЕ `getApplicationDocumentsDirectory()` — у Flutter тот
  /// указывает на `app_flutter`, у native/ядра это `files`. Пока канал
  /// ходил по Dart-пути, файлы ядра не находились НИКОГДА (device-verified
  /// §316). Фоллбэк на Dart-путь оставлен для юнит-тестов, где
  /// MethodChannel не поднят.
  static Future<String> baseDir() async {
    final native = await BoxVpnClient().getFilesDir();
    if (native != null && native.isNotEmpty) return native;
    return (await getApplicationDocumentsDirectory()).path;
  }

  /// Все доступные репорты, **новые первыми**: архив `crash_reports/` плюс
  /// текущий, если он непуст (текущая сессия ещё не архивирована ядром).
  static Future<List<CrashReportFile>> list() async {
    final out = <CrashReportFile>[];
    try {
      final base = await baseDir();
      final current = File('$base/$kCrashReportBaseName');
      if (await current.exists()) {
        final stat = await current.stat();
        if (stat.size > 0) {
          out.add(CrashReportFile(
            path: current.path,
            name: kCrashReportBaseName,
            mtime: stat.modified,
            size: stat.size,
            isCurrent: true,
          ));
        }
      }
      out.addAll(await _archive(base));
    } catch (_) {
      return out;
    }
    out.sort((a, b) => b.mtime.compareTo(a.mtime));
    return out;
  }

  /// Архивные репорты. Каждый — КАТАЛОГ `<таймстамп>/` с `go.log` внутри
  /// (см. [CrashReportFile]). Записи без `go.log` пропускаем: это не репорт,
  /// а мусор/недописанный каталог, и делать вид, что он есть, — врать.
  ///
  /// Поддержан и плоский файл прямо в `crash_reports/`: ранние сборки ядра
  /// клали репорты так, и у части пользователей они ещё лежат.
  static Future<List<CrashReportFile>> _archive(String base) async {
    final dir = Directory('$base/$kCrashArchiveDir');
    if (!await dir.exists()) return const [];
    final out = <CrashReportFile>[];
    await for (final entity in dir.list(followLinks: false)) {
      final name = entity.uri.pathSegments
          .lastWhere((s) => s.isNotEmpty, orElse: () => '');
      if (entity is Directory) {
        final log = File('${entity.path}/$kCrashTraceName');
        if (!await log.exists()) continue;
        final stat = await log.stat();
        out.add(CrashReportFile(
          path: log.path,
          name: name,
          mtime: stat.modified,
          size: stat.size,
          isCurrent: false,
          dirPath: entity.path,
          coreVersion: await _coreVersionOf(entity.path),
        ));
      } else if (entity is File) {
        final stat = await entity.stat();
        out.add(CrashReportFile(
          path: entity.path,
          name: name,
          mtime: stat.modified,
          size: stat.size,
          isCurrent: false,
        ));
      }
    }
    return out;
  }

  /// `coreVersion` из `metadata.json` репорта; `null` если файла нет или он
  /// не читается — метаданные приятны, но не обязательны для показа.
  static Future<String?> _coreVersionOf(String dirPath) async {
    try {
      final f = File('$dirPath/$kCrashMetaName');
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is Map && j['coreVersion'] is String) return j['coreVersion'];
    } catch (_) {
      // Битый JSON — не повод прятать сам репорт.
    }
    return null;
  }

  /// Оставляет [keep] свежих архивных репортов, остальные удаляет.
  ///
  /// Чистим МЫ, а не ядро: `archiveCrashReport` только докладывает файлы и
  /// размер папки не ограничивает — она растёт от каждого запуска. Зовётся
  /// на старте приложения, а не при открытии экрана: в Diagnostics юзер
  /// может не заходить годами.
  ///
  /// Возвращает число удалённых репортов (для лога/тестов).
  static Future<int> prune({int keep = kCrashKeep}) async {
    try {
      final base = await baseDir();
      final archive = await _archive(base);
      if (archive.length <= keep) return 0;
      archive.sort((a, b) => b.mtime.compareTo(a.mtime));
      var removed = 0;
      for (final r in archive.skip(keep)) {
        try {
          // Репорт = каталог целиком (трейс + метаданные + конфиг); у
          // legacy-репортов каталога нет, там удаляем сам файл.
          final dir = r.dirPath;
          if (dir != null) {
            await Directory(dir).delete(recursive: true);
          } else {
            await File(r.path).delete();
          }
          removed++;
        } catch (_) {
          // Занят/исчез — не повод валить старт.
        }
      }
      return removed;
    } catch (_) {
      return 0;
    }
  }

  /// Стабильный идентификатор репорта для отметки «баннер уже показан»:
  /// имя + mtime. Привязка к КОНКРЕТНОМУ крашу, а не к факту показа —
  /// иначе либо покажем дважды, либо новый краш промолчит.
  static String stamp(CrashReportFile f) =>
      '${f.name}@${f.mtime.toUtc().toIso8601String()}';
}
