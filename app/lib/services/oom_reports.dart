import 'dart:convert';
import 'dart:io';

import 'stderr_reader.dart' show CrashReports;

/// §318 — подпапка, куда ЯДРО складывает OOM-снимки.
///
/// Пишет их `oomReporter.WriteReport` (`experimental/libbox/oom_report.go`),
/// когда oom-killer ядра (§271, `SetupOptions.oomKillerEnabled`) видит
/// превышение порога RSS. Размер архива ядро не ограничивает вообще —
/// ротацию делаем мы ([OomReports.prune]). На тест-устройстве папка доросла
/// до 575 снимков / 427 МБ, прежде чем её вообще заметили.
const kOomArchiveDir = 'oom_reports';

/// §318 — головной файл снимка: memstats на момент срабатывания killer'а.
///
/// Именно он, а НЕ `go.log` (в отличие от краш-репортов §316): ценность
/// OOM-снимка в цифрах памяти, и их надо видеть в списке без открытия.
/// Каталог без этого файла — недописанный снимок, а не отчёт.
const kOomMetaName = 'metadata.json';

/// §318 — лог ядра на момент снимка; показываем вторым блоком при просмотре.
const kOomLogName = 'go.log';

/// §318 — сколько снимков держим.
///
/// Меньше, чем `kCrashKeep = 10`: снимок OOM это ~750 КБ (два pprof-профиля
/// кучи по 580 КБ), десяток съел бы 7.5 МБ против нескольких КБ у краша.
const kOomKeep = 5;

/// Один OOM-снимок ядра: каталог `oom_reports/<ISO-таймстамп>/`.
///
/// [path] указывает на `metadata.json` — головной файл; [size] — размер
/// **всего каталога**, а не головного файла: вес несут pprof-профили, и в
/// UI надо видеть реальные мегабайты, а не полкилобайта метаданных.
class OomReportFile {
  const OomReportFile({
    required this.path,
    required this.name,
    required this.mtime,
    required this.size,
    required this.dirPath,
    this.coreVersion,
    this.memoryUsage,
    this.heapInuse,
    this.numGoroutine,
  });

  /// Путь к `metadata.json` снимка.
  final String path;

  /// Имя каталога — ISO-таймстамп, он же имя для показа/share.
  final String name;
  final DateTime mtime;

  /// Суммарный размер каталога (профили + лог + конфиг + метаданные).
  final int size;

  /// Каталог снимка — share отдаёт его целиком.
  final String dirPath;

  /// Версия ядра из `metadata.json`: сразу видно, актуален ли снимок.
  final String? coreVersion;

  /// RSS процесса на момент срабатывания killer'а (уже отформатирован
  /// ядром, напр. `440 MB`) — главная цифра снимка.
  final String? memoryUsage;

  /// Занятая куча Go — вместе с [memoryUsage] отделяет утечку в Go-куче от
  /// роста вне её (буферы, треды, нативные аллокации).
  final String? heapInuse;

  /// Число горутин: рост при стабильной куче — подпись утечки горутин.
  final int? numGoroutine;
}

/// §318 — история OOM-снимков ядра: список, размер, ротация, очистка.
///
/// Полный симметричный аналог `CrashReports` (§316) для второго канала
/// улик. Каталог тот же — native `Context.filesDir` через
/// [CrashReports.baseDir]: ядро пишет туда, а НЕ в Flutter-овый
/// `getApplicationDocumentsDirectory()` (§316 §2.0 — на этом канал §038
/// молчал с самого введения).
class OomReports {
  /// Все снимки, **новые первыми**.
  static Future<List<OomReportFile>> list() async {
    try {
      final base = await CrashReports.baseDir();
      final reports = await _scan(base);
      reports.sort((a, b) => b.mtime.compareTo(a.mtime));
      return reports;
    } catch (_) {
      return const [];
    }
  }

  /// Суммарный размер архива в байтах — для заголовка вкладки.
  ///
  /// Считаем по [list], а не отдельным обходом: один источник правды, и
  /// цифра гарантированно совпадает с суммой строк списка.
  static Future<int> totalSize() async {
    final reports = await list();
    var total = 0;
    for (final r in reports) {
      total += r.size;
    }
    return total;
  }

  /// Обход архива. Снимок — это КАТАЛОГ с `metadata.json` внутри; записи
  /// без него пропускаем (недописанный снимок/мусор — показывать его значит
  /// врать, что отчёт есть).
  static Future<List<OomReportFile>> _scan(String base) async {
    final dir = Directory('$base/$kOomArchiveDir');
    if (!await dir.exists()) return const [];
    final out = <OomReportFile>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final meta = File('${entity.path}/$kOomMetaName');
      if (!await meta.exists()) continue;
      final name = entity.uri.pathSegments
          .lastWhere((s) => s.isNotEmpty, orElse: () => '');
      final stat = await meta.stat();
      final fields = await _metaOf(meta);
      out.add(OomReportFile(
        path: meta.path,
        name: name,
        mtime: stat.modified,
        size: await _dirSize(entity),
        dirPath: entity.path,
        coreVersion: fields['coreVersion'] as String?,
        memoryUsage: fields['memoryUsage'] as String?,
        heapInuse: fields['heapInuse'] as String?,
        numGoroutine: _asInt(fields['numGoroutine']),
      ));
    }
    return out;
  }

  /// Размер каталога снимка. Профили лежат плоско, но обходим рекурсивно —
  /// дешевле, чем закладываться на неизменность раскладки ядра.
  static Future<int> _dirSize(Directory dir) async {
    var total = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        try {
          total += await e.length();
        } catch (_) {
          // Файл исчез во время обхода — пропускаем, не валим весь список.
        }
      }
    } catch (_) {
      return total;
    }
    return total;
  }

  /// Поля `metadata.json`; пустая карта, если файл битый или не читается —
  /// метаданные приятны, но не повод прятать сам снимок.
  static Future<Map<String, Object?>> _metaOf(File meta) async {
    try {
      final j = jsonDecode(await meta.readAsString());
      if (j is Map) return j.cast<String, Object?>();
    } catch (_) {
      // Битый JSON — снимок всё равно показываем, профили в нём целы.
    }
    return const {};
  }

  /// `numGoroutine` приходит строкой (`json:",string"` в Go-структуре), но
  /// терпим и число: поле метаданных не повод падать при бампе ядра.
  static int? _asInt(Object? v) => switch (v) {
        int i => i,
        String s => int.tryParse(s),
        _ => null,
      };

  /// Оставляет [keep] свежих снимков, остальные удаляет.
  ///
  /// Зовётся на старте приложения, а не при открытии экрана: в Diagnostics
  /// пользователь может не заходить годами — именно так на тест-устройстве
  /// и накопилось 427 МБ.
  ///
  /// Возвращает число удалённых снимков (для лога/тестов).
  static Future<int> prune({int keep = kOomKeep}) async {
    try {
      final reports = await list();
      if (reports.length <= keep) return 0;
      var removed = 0;
      for (final r in reports.skip(keep)) {
        if (await _delete(r)) removed++;
      }
      return removed;
    } catch (_) {
      return 0;
    }
  }

  /// Удаляет все снимки — кнопка «Delete all» на вкладке.
  ///
  /// Возвращает число удалённых.
  static Future<int> clear() async {
    try {
      var removed = 0;
      for (final r in await list()) {
        if (await _delete(r)) removed++;
      }
      return removed;
    } catch (_) {
      return 0;
    }
  }

  /// Снимок = каталог целиком. `false`, если удалить не вышло (занят/исчез) —
  /// не повод валить старт или очистку остальных.
  static Future<bool> _delete(OomReportFile r) async {
    try {
      await Directory(r.dirPath).delete(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }
}
