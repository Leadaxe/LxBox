import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../../vpn/box_vpn_client.dart';
import '../../rule_set_downloader.dart';
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

/// Allow-list файлов в internal app-scoped storage
/// (`/data/data/<pkg>/files/`, `getApplicationDocumentsDirectory()`).
/// Выдаём только sing-box core stderr и HTTP cache — полезно для
/// диагностики. До task 027 файлы лежали в external storage; теперь
/// internal по причине Knox/SELinux quirks на отдельных OEM.
/// §316 — базовое имя краш-репорта ядра. Совпадает с `crashReportSource`
/// из `BoxApplication` (`SetupOptions.crashReportSource = "lxbox"`): ядро
/// редиректит Go-stderr в `workingPath/CrashReport-<source>.log`
/// (`experimental/libbox/setup.go`), где `workingPath` = native
/// `Context.filesDir`. ВАЖНО: это НЕ `getApplicationDocumentsDirectory()` —
/// у Flutter тот указывает на `app_flutter`, у native/ядра это `files`.
/// Пока §038-канал ходил по Dart-пути, файлы ядра не находились НИКОГДА
/// (device-verified §316). Путь берём у native (`getFilesDir`).
const kCrashReportBaseName = 'CrashReport-lxbox.log';

/// §316 — подпапка, куда ядро архивирует ПРОШЛЫЕ репорты при каждом
/// `Setup()` (`archiveCrashReport`).
const _crashArchiveDir = 'crash_reports';

const _localWhitelist = {
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
Future<DebugResponse> _crashList() async {
  final base = await _nativeFilesDir();
  final dir = Directory('$base/$_crashArchiveDir');
  if (!await dir.exists()) return const JsonResponse([]);
  final entries = <({String name, int size, DateTime mtime})>[];
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final stat = await entity.stat();
    entries.add((
      name: entity.uri.pathSegments.last,
      size: stat.size,
      mtime: stat.modified,
    ));
  }
  entries.sort((a, b) => b.mtime.compareTo(a.mtime)); // новые первыми
  return JsonResponse([
    for (final e in entries)
      {
        'name': e.name,
        'size': e.size,
        'mtime': e.mtime.toUtc().toIso8601String(),
      },
  ]);
}

/// §316 — тело архивного краш-репорта. Подпапка задаётся СЕРВЕРОМ, клиент
/// передаёт только basename (гейт `_assertSafeName`) — traversal невозможен
/// по построению, поэтому `/files/local` не пришлось учить путям со слэшем.
Future<DebugResponse> _crashFile(DebugRequest req) async {
  final name = req.requiredQuery('name');
  _assertSafeName(name);
  final base = await _nativeFilesDir();
  final f = File('$base/$_crashArchiveDir/$name');
  if (!await f.exists()) throw NotFound('crash report: $name');
  final bytes = await f.readAsBytes();
  return BytesResponse(bytes, filename: name);
}

/// §316 — native `Context.filesDir` с фоллбэком на Dart-путь (юнит-тесты,
/// где MethodChannel не поднят). Фоллбэк намеренно НЕ молчаливый по смыслу:
/// на устройстве канал всегда есть, а в тестах путь подменяется фейком
/// path_provider.
Future<String> _nativeFilesDir() async {
  final native = await BoxVpnClient().getFilesDir();
  if (native != null && native.isNotEmpty) return native;
  return (await getApplicationDocumentsDirectory()).path;
}

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
