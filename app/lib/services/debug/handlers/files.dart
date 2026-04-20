import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../rule_set_downloader.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `/files/*` — read-only доступ к кэшированным файлам и whitelist'нутым
/// файлам из app-scoped external storage.
Future<DebugResponse> filesHandler(DebugRequest req, DebugContext ctx) async {
  return switch (req.path) {
    '/files/srs/list' => _srsList(ctx),
    '/files/srs' => _srsFile(req, ctx),
    '/files/external' => _externalFile(req, ctx),
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

/// Allow-list файлов в app-scoped external storage
/// (`/sdcard/Android/data/<pkg>/files/`). Выдаём только sing-box core
/// stderr и HTTP cache — полезно для диагностики.
const _externalWhitelist = {
  'stderr.log',
  'stderr.log.old',
  'cache.db',
};

Future<DebugResponse> _externalFile(DebugRequest req, DebugContext ctx) async {
  final name = req.requiredQuery('name');
  _assertSafeName(name);
  if (!_externalWhitelist.contains(name)) {
    throw NotFound('not whitelisted: $name');
  }
  final dir = await getExternalStorageDirectory();
  if (dir == null) throw const Conflict('external storage unavailable');
  final f = File('${dir.path}/$name');
  if (!await f.exists()) throw NotFound('file: $name');
  final bytes = await f.readAsBytes();
  return BytesResponse(bytes, filename: name);
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
