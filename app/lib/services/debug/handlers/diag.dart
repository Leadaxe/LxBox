import 'dart:convert';
import 'dart:io';

import '../../../models/debug_entry.dart';
import '../../../vpn/box_vpn_client.dart';
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
    '/diag/pprof' => _pprof(req),
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

/// §207 — обобщённый pprof-снимок через libbox `PProfServer` (Способ 1).
/// Один сервер бесплатно отдаёт весь набор `/debug/pprof/*`, поэтому один
/// хэндлер вместо плодить по штуке на профиль.
///
/// `?profile=goroutine|profile|heap|allocs|block|mutex|threadcreate`
///   (default `goroutine`).
/// `?query=...` — сырой pprof-query без `?` (напр. `gc=1`, `debug=1`,
///   `seconds=20`). Default по профилю: goroutine→`debug=2`, profile→
///   `seconds=10`, heap→`gc=1`, прочие→пусто.
///
/// Только `goroutine?debug=1|2` отдаётся как text/plain; остальные —
/// бинарный `.pb` (application/octet-stream, `go tool pprof`).
/// Туннель должен быть активен (без ядра сервер не поднять).
Future<DebugResponse> _pprof(DebugRequest req) async {
  final profile = (req.query['profile'] ?? 'goroutine').trim();
  if (!_pprofProfiles.contains(profile)) {
    throw BadRequest(
        'unknown pprof profile: $profile (allowed: ${_pprofProfiles.join('|')})');
  }
  // Сырой query: явный ?query=... либо дефолт по профилю.
  final query = (req.query['query'] ?? _defaultQuery(profile)).trim();
  final pathAndQuery = query.isEmpty ? profile : '$profile?$query';

  // Блокирующий — только CPU `profile`; вытащим seconds для масштабирования.
  final blockingSeconds = profile == 'profile'
      ? (int.tryParse(RegExp(r'seconds=(\d+)').firstMatch(query)?.group(1) ?? '10') ??
              10)
          .clamp(1, 60)
      : 0;
  final bytes = await BoxVpnClient()
      .pprofRaw(pathAndQuery, blockingSeconds: blockingSeconds);

  // Текст только для читаемого goroutine-дампа.
  final isText = profile == 'goroutine' && query.startsWith('debug=');
  return isText
      ? BytesResponse(bytes, contentType: 'text/plain; charset=utf-8')
      : BytesResponse(bytes,
          filename: '$profile.pb', contentType: 'application/octet-stream');
}

String _defaultQuery(String profile) => switch (profile) {
      'goroutine' => 'debug=2',
      'profile' => 'seconds=10',
      'heap' => 'gc=1',
      _ => '',
    };

/// Поддерживаемые pprof-профили (зеркало Go `net/http/pprof`).
const _pprofProfiles = <String>{
  'goroutine',
  'profile',
  'heap',
  'allocs',
  'block',
  'mutex',
  'threadcreate',
};

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
