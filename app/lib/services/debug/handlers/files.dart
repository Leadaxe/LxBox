import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../oom_reports.dart'
    show kOomArchiveDir, kOomMetaName, OomReports;
import '../../rule_set_downloader.dart';
import '../../stderr_reader.dart'
    show kCrashArchiveDir, kCrashReportBaseName, kCrashTraceName, CrashReports;
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `/files/*` — read-only доступ к кэшированным файлам и whitelist'нутым
/// файлам из internal app-scoped storage (`/data/data/<pkg>/files/`).
///
/// `/files/local` — современный путь.
/// `/files/external` — исторический alias, оставлен ради обратной
/// совместимости с adb-скриптами; раньше файлы лежали в external storage,
/// после task 027 — в internal. Имя URL поменять без deprecation-цикла
/// нельзя.
Future<DebugResponse> filesHandler(DebugRequest req, DebugContext ctx) async {
  return switch (req.path) {
    '/files/srs/list' => _srsList(ctx),
    '/files/srs' => _srsFile(req, ctx),
    '/files/local' || '/files/external' => _localFile(req, ctx),
    // §316 — архив краш-репортов ядра (ротация делается самим ядром).
    '/files/crash/list' => _crashList(),
    '/files/crash' => _crashFile(req),
    // §318 — OOM-снимки ядра: те же две операции над вторым архивом.
    '/files/oom/list' => _oomList(),
    '/files/oom' => _oomFile(req),
    _ => throw NotFound('files path: ${req.path}'),
  };
}

/// Список `.srs` в кэше: `{ruleId, size, mtime}[]`.
Future<DebugResponse> _srsList(DebugContext ctx) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/rule_sets');
  if (!await dir.exists()) return const JsonResponse([]);
  final entries = <Map<String, Object?>>[];
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    if (!name.endsWith('.srs')) continue;
    final stat = await entity.stat();
    entries.add({
      'rule_id': name.substring(0, name.length - 4),
      'size': stat.size,
      'mtime': stat.modified.toUtc().toIso8601String(),
    });
  }
  return JsonResponse(entries);
}

Future<DebugResponse> _srsFile(DebugRequest req, DebugContext ctx) async {
  final id = req.requiredQuery('ruleId');
  _assertSafeName(id);
  final path = await RuleSetDownloader.cachedPath(id);
  if (path == null) throw NotFound('srs for ruleId=$id');
  final f = File(path);
  if (!await f.exists()) throw NotFound('srs file: $path');
  final bytes = await f.readAsBytes();
  return BytesResponse(bytes, filename: '$id.srs');
}

/// Allow-list файлов в internal app-scoped storage (native `Context.filesDir`,
/// `/data/data/<pkg>/files/`). Выдаём только sing-box core stderr и HTTP
/// cache — полезно для диагностики. До task 027 файлы лежали в external
/// storage; теперь internal по причине Knox/SELinux quirks на отдельных OEM.
const _localWhitelist = {
  // Имя до libbox 1.14 — ядро его больше не пишет. Оставлено как read-only
  // эндпоинт для устройств со старым файлом; UI-канал на него НЕ смотрит
  // (§2.4 §316), там читается только `kCrashReportBaseName`.
  'stderr.log',
  'cache.db',
  // §316 — Go-паники ядра. Без этих имён история крашей физически лежала
  // на устройстве, но была недостижима через API (разрыв §173-переезда).
  kCrashReportBaseName,
  '$kCrashReportBaseName.old',
};

Future<DebugResponse> _localFile(DebugRequest req, DebugContext ctx) async {
  final name = req.requiredQuery('name');
  _assertSafeName(name);
  if (!_localWhitelist.contains(name)) {
    throw NotFound('not whitelisted: $name');
  }
  // §316 — native filesDir: ядро и AppLog пишут именно туда.
  final base = await _nativeFilesDir();
  final f = File('$base/$name');
  if (!await f.exists()) throw NotFound('file: $name');
  final bytes = await f.readAsBytes();
  return BytesResponse(bytes, filename: name);
}

/// §316 — архив краш-репортов ядра: `[{name, size, mtime}]`, новые первыми.
///
/// Пустой список (а не 404) при отсутствии папки — «крашей не было» это
/// валидное состояние, а не ошибка запроса.
/// Обход архива делегирован `CrashReports.list()` — один источник правды с
/// UI. Своя реализация тут уже разошлась с реальностью: ядро складывает
/// репорты КАТАЛОГАМИ `<таймстамп>/{go.log,metadata.json,configuration.json}`,
/// а обход брал только файлы и молча отдавал `[]` при полном архиве.
Future<DebugResponse> _crashList() async {
  final reports =
      (await CrashReports.list()).where((r) => !r.isCurrent).toList();
  return JsonResponse([
    for (final r in reports)
      {
        'name': r.name,
        'size': r.size,
        'mtime': r.mtime.toUtc().toIso8601String(),
        if (r.coreVersion != null) 'core_version': r.coreVersion,
        // Каталог отдаётся пофайлово через `?name=<repo>&file=<...>`.
        if (r.dirPath != null) 'kind': 'dir',
      },
  ]);
}

/// §316 — тело архивного краш-репорта: по умолчанию `go.log`, конкретный
/// файл каталога — через `&file=`. Подпапка задаётся СЕРВЕРОМ, клиент
/// передаёт только basename'ы (гейт `_assertSafeName`) — traversal невозможен
/// по построению, поэтому `/files/local` не пришлось учить путям со слэшем.
Future<DebugResponse> _crashFile(DebugRequest req) async {
  final name = req.requiredQuery('name');
  _assertSafeName(name);
  final inner = req.uri.queryParameters['file'];
  if (inner != null) _assertSafeName(inner);
  final base = await _nativeFilesDir();
  final root = '$base/$kCrashArchiveDir/$name';
  // Каталог-репорт (текущая схема ядра) или плоский файл (ранние сборки).
  final f = await Directory(root).exists()
      ? File('$root/${inner ?? kCrashTraceName}')
      : File(root);
  if (!await f.exists()) throw NotFound('crash report: $name');
  final bytes = await f.readAsBytes();
  return BytesResponse(bytes, filename: '$name-${f.uri.pathSegments.last}');
}

/// §318 — OOM-снимки ядра: `[{name, size, mtime, ...memstats}]`, новые
/// первыми. `size` — размер ВСЕГО каталога: вес несут pprof-профили.
///
/// Пустой список (а не 404) при отсутствии папки: «killer не срабатывал» —
/// валидное состояние, а не ошибка запроса.
Future<DebugResponse> _oomList() async {
  final reports = await OomReports.list();
  return JsonResponse([
    for (final r in reports)
      {
        'name': r.name,
        'size': r.size,
        'mtime': r.mtime.toUtc().toIso8601String(),
        if (r.coreVersion != null) 'core_version': r.coreVersion,
        if (r.memoryUsage != null) 'memory_usage': r.memoryUsage,
        if (r.heapInuse != null) 'heap_inuse': r.heapInuse,
        if (r.numGoroutine != null) 'num_goroutine': r.numGoroutine,
      },
  ]);
}

/// §318 — файл OOM-снимка: по умолчанию `metadata.json`, конкретный —
/// через `&file=` (`heap.pb`, `allocs.pb`, `go.log`, `configuration.json`,
/// `connections.json`). Подпапка задаётся СЕРВЕРОМ, клиент передаёт только
/// basename'ы (гейт `_assertSafeName`) — traversal невозможен по построению.
Future<DebugResponse> _oomFile(DebugRequest req) async {
  final name = req.requiredQuery('name');
  _assertSafeName(name);
  final inner = req.uri.queryParameters['file'];
  if (inner != null) _assertSafeName(inner);
  final base = await _nativeFilesDir();
  final f = File('$base/$kOomArchiveDir/$name/${inner ?? kOomMetaName}');
  if (!await f.exists()) throw NotFound('oom report: $name');
  final bytes = await f.readAsBytes();
  return BytesResponse(bytes, filename: '$name-${f.uri.pathSegments.last}');
}

/// §316 — native `Context.filesDir` (см. [CrashReports.baseDir]): ядро и
/// AppLog пишут именно туда, а НЕ в `getApplicationDocumentsDirectory()`.
Future<String> _nativeFilesDir() => CrashReports.baseDir();

/// Защита от path traversal. Имя файла — только basename,
/// без `/`, `\`, `..`, ведущей точки.
void _assertSafeName(String name) {
  if (name.isEmpty ||
      name.contains('/') ||
      name.contains('\\') ||
      name.contains('..') ||
      name.startsWith('.')) {
    throw BadRequest('invalid name: only basename allowed');
  }
}
