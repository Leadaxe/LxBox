import '../../../models/debug_entry.dart';
import '../../app_log.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `/logs` — GET (list) + POST /logs/clear.
///
/// Параметры GET:
/// * `limit` — int, default 200, max 500 (реальный кэп AppLog'а)
/// * `source` — `app|core`, иначе все
Future<DebugResponse> logsHandler(DebugRequest req, DebugContext ctx) async {
  if (req.path == '/logs' && req.method == 'GET') {
    return _list(req, ctx);
  }
  if (req.path == '/logs/clear' && req.method == 'POST') {
    return _clear(req, ctx);
  }
  throw NotFound('logs path: ${req.method} ${req.path}');
}

Future<DebugResponse> _list(DebugRequest req, DebugContext ctx) async {
  final limit = (req.qInt('limit') ?? 200).clamp(1, 500);
  final source = req.q('source');
  var entries = AppLog.I.entries;
  if (source == 'app') {
    entries = entries.where((e) => e.source == DebugSource.app).toList();
  } else if (source == 'core') {
    entries = entries.where((e) => e.source == DebugSource.core).toList();
  } else if (source != null && source.isNotEmpty) {
    throw BadRequest('source must be "app" or "core", got "$source"');
  }
  final slice = entries.take(limit).toList();
  return JsonResponse(slice.map(_entryToJson).toList());
}

Map<String, Object?> _entryToJson(DebugEntry e) => {
      'ts': e.time.toUtc().toIso8601String(),
      'level': e.level.name,
      'source': e.source.name,
      'message': e.message,
    };

Future<DebugResponse> _clear(DebugRequest req, DebugContext ctx) async {
  AppLog.I.clear();
  return const JsonResponse({'ok': true, 'action': 'clear'});
}
