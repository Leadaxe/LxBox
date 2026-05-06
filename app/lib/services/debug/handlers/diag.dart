import 'dart:convert';
import 'dart:io';

import '../../../models/debug_entry.dart';
import '../../app_log.dart';
import '../../dump_builder.dart';
import '../../exit_info_reader.dart';
import '../../logcat_reader.dart';
import '../../stderr_reader.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `/diag/*` — §038 crash diagnostics endpoints. Все 4 канала + единый
/// dump-pack доступны через HTTP без UI.
Future<DebugResponse> diagHandler(DebugRequest req, DebugContext ctx) async {
  return switch (req.path) {
    '/diag/dump' => _dump(),
    '/diag/exit-info' => _exitInfo(),
    '/diag/logcat' => _logcat(req),
    '/diag/stderr' => _stderr(),
    '/diag/applog' => _applog(req),
    _ => throw NotFound('diag path: ${req.path}'),
  };
}

/// Полный JSON-pack от `DumpBuilder.build()` — то же что отдаёт UI ⤴ Share.
Future<DebugResponse> _dump() async {
  final path = await DumpBuilder.build();
  final bytes = await File(path).readAsBytes();
  return BytesResponse(bytes,
      filename: path.split('/').last, contentType: 'application/json');
}

/// `ApplicationExitInfo` записи (последние 5). Канал B §038.
/// На API <30 — пустой массив.
Future<DebugResponse> _exitInfo() async =>
    JsonResponse(await ExitInfoReader.read());

/// Logcat tail — канал D §038. `?count=50..5000`, `?level=V|D|I|W|E|F`.
Future<DebugResponse> _logcat(DebugRequest req) async {
  final count = int.tryParse(req.query['count'] ?? '1000') ?? 1000;
  final level = (req.query['level'] ?? 'E').trim();
  final text = await LogcatReader.tail(count: count, level: level) ?? '';
  return BytesResponse(utf8.encode(text), contentType: 'text/plain; charset=utf-8');
}

/// `stderr.log` content — канал A §038. Alias на `/files/local?name=stderr.log`.
Future<DebugResponse> _stderr() async {
  final text = await StderrReader.read() ?? '';
  return BytesResponse(utf8.encode(text), contentType: 'text/plain; charset=utf-8');
}

/// AppLog entries — канал C §038. `?prev=true|false|all` (default `all`):
/// фильтр по `fromPreviousSession`.
Future<DebugResponse> _applog(DebugRequest req) async {
  final filter = (req.query['prev'] ?? 'all').toLowerCase();
  final entries = AppLog.I.entries.where((e) => switch (filter) {
        'true' => e.fromPreviousSession,
        'false' => !e.fromPreviousSession,
        _ => true,
      });
  return JsonResponse(entries
      .map((e) => {
            'time': e.time.toIso8601String(),
            'source': e.source == DebugSource.core ? 'core' : 'app',
            'level': e.level.name,
            'message': e.message,
            if (e.fromPreviousSession) 'prev_session': true,
          })
      .toList());
}
