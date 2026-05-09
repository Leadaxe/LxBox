// §044 / §048 — Debug API handler for `/profiler/*`.
//
// Endpoints:
//   POST   /profiler/start          { package, verbose?, secondary_packages? }
//   POST   /profiler/stop
//   GET    /profiler/active
//   GET    /profiler/sessions
//   GET    /profiler/session/<id>?include=events,domains,ips
//   DELETE /profiler/session/<id>
//   DELETE /profiler/sessions
//   GET    /profiler/stream         (SSE — per-session, fire-and-forget)
//   PATCH  /profiler/secondary-packages { secondary_packages: [...] }
//
//   §048 inclusive observer:
//   GET    /profiler/live?seconds=60     — global rolling buffer snapshot
//   GET    /profiler/live/stream         — SSE stream of all events system-wide
//   GET    /profiler/live/unattributed   — recent unattributed (DNS fail без owner etc)

import 'dart:convert';

import '../../traffic_profiler.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

Future<DebugResponse> profilerHandler(
    DebugRequest req, DebugContext ctx) async {
  final path = req.path;
  // /profiler/session/<id>
  if (path.startsWith('/profiler/session/')) {
    final id = path.substring('/profiler/session/'.length);
    if (id.isEmpty) throw const NotFound('missing session id');
    return switch (req.method) {
      'GET' => _getSession(req, id),
      'DELETE' => _deleteSession(req, id),
      _ => throw BadRequest(
          'method ${req.method} not allowed on /profiler/session/<id>'),
    };
  }
  return switch (path) {
    '/profiler/start' => _start(req),
    '/profiler/stop' => _stop(req),
    '/profiler/active' => _active(req),
    '/profiler/sessions' => req.method == 'DELETE'
        ? _clearSessions(req)
        : _listSessions(req),
    '/profiler/stream' => _stream(req),
    '/profiler/live' => _live(req),
    '/profiler/live/stream' => _liveStream(req),
    '/profiler/live/unattributed' => _liveUnattributed(req),
    '/profiler/secondary-packages' => _patchSecondaryPackages(req),
    _ => throw NotFound('profiler path: $path'),
  };
}

Future<DebugResponse> _start(DebugRequest req) async {
  if (req.method != 'POST') {
    throw BadRequest('method ${req.method} not allowed (POST required)');
  }
  Map<String, dynamic> body = const {};
  if (req.body.isNotEmpty) {
    try {
      final parsed = jsonDecode(utf8.decode(req.body));
      if (parsed is Map<String, dynamic>) body = parsed;
    } catch (e) {
      throw BadRequest('invalid JSON body: $e');
    }
  }
  final pkg = body['package']?.toString() ?? '';
  if (pkg.isEmpty) throw const BadRequest('missing package');
  final verbose = body['verbose'] == true;
  final rawSecondary = body['secondary_packages'];
  final secondary = <String>{};
  if (rawSecondary is List) {
    for (final item in rawSecondary) {
      final s = item?.toString().trim() ?? '';
      if (s.isNotEmpty) secondary.add(s);
    }
  }

  if (TrafficProfiler.I.isRecording) {
    return JsonResponse(
      {
        'error': 'already_active',
        'active_session_id': TrafficProfiler.I.active!.id,
      },
      status: 409,
    );
  }
  final s = await TrafficProfiler.I.start(
    pkg,
    verbose: verbose,
    secondaryPackages: secondary.isEmpty ? null : secondary,
  );
  return JsonResponse(s.toMetaJson());
}

Future<DebugResponse> _stop(DebugRequest req) async {
  if (req.method != 'POST') {
    throw BadRequest('method ${req.method} not allowed (POST required)');
  }
  final s = await TrafficProfiler.I.stop();
  if (s == null) {
    return JsonResponse({'error': 'no_active_session'}, status: 404);
  }
  return JsonResponse(s.toMetaJson());
}

Future<DebugResponse> _active(DebugRequest req) async {
  if (req.method != 'GET') {
    throw BadRequest('method ${req.method} not allowed (GET required)');
  }
  final s = TrafficProfiler.I.active;
  if (s == null) {
    return JsonResponse({'error': 'no_active_session'}, status: 404);
  }
  return JsonResponse(s.toMetaJson());
}

Future<DebugResponse> _listSessions(DebugRequest req) async {
  if (req.method != 'GET') {
    throw BadRequest('method ${req.method} not allowed (GET required)');
  }
  final list = TrafficProfiler.I.completed.map((s) => s.toMetaJson()).toList();
  return JsonResponse({'sessions': list});
}

Future<DebugResponse> _clearSessions(DebugRequest req) async {
  if (req.method != 'DELETE') {
    throw BadRequest('method ${req.method} not allowed (DELETE required)');
  }
  final n = TrafficProfiler.I.clearAll();
  return JsonResponse({'ok': true, 'deleted': n});
}

Future<DebugResponse> _getSession(DebugRequest req, String id) async {
  final s = TrafficProfiler.I.getById(id);
  if (s == null) throw NotFound('session: $id');
  final include = (req.query['include'] ?? '').split(',').toSet();
  final out = <String, Object?>{...s.toMetaJson()};
  if (include.contains('events')) {
    out['events'] = s.events.map((e) => e.toJson()).toList();
  }
  if (include.contains('domains')) {
    out['by_domain'] = s.byDomain.values.map((d) => d.toJson()).toList();
  }
  if (include.contains('ips')) {
    out['by_ip'] = s.byIp.values.map((i) => i.toJson()).toList();
  }
  return JsonResponse(out);
}

Future<DebugResponse> _deleteSession(DebugRequest req, String id) async {
  final ok = TrafficProfiler.I.delete(id);
  if (!ok) throw NotFound('session: $id');
  return JsonResponse({'ok': true});
}

Future<DebugResponse> _stream(DebugRequest req) async {
  if (req.method != 'GET') {
    throw BadRequest('method ${req.method} not allowed (GET required)');
  }
  return SseResponse(TrafficProfiler.I.liveStream());
}

// ─── §048 inclusive observer endpoints ──────────────────────────────────

Future<DebugResponse> _live(DebugRequest req) async {
  if (req.method != 'GET') {
    throw BadRequest('method ${req.method} not allowed (GET required)');
  }
  final secondsStr = req.query['seconds'] ?? '60';
  final seconds = int.tryParse(secondsStr) ?? 60;
  final events = TrafficProfiler.I.globalSnapshot(seconds: seconds);
  return JsonResponse({
    'window_seconds': seconds,
    'count': events.length,
    'events': events.map((e) => e.toJson()).toList(),
  });
}

Future<DebugResponse> _liveStream(DebugRequest req) async {
  if (req.method != 'GET') {
    throw BadRequest('method ${req.method} not allowed (GET required)');
  }
  return SseResponse(TrafficProfiler.I.globalLiveStream());
}

Future<DebugResponse> _liveUnattributed(DebugRequest req) async {
  if (req.method != 'GET') {
    throw BadRequest('method ${req.method} not allowed (GET required)');
  }
  final events = TrafficProfiler.I.globalUnattributedEvents;
  return JsonResponse({
    'count': events.length,
    'recent_count_30s': TrafficProfiler.I.recentUnattributedCount,
    'banner_active': TrafficProfiler.I.unattributedBannerActive,
    'events': events.map((e) => e.toJson()).toList(),
  });
}

Future<DebugResponse> _patchSecondaryPackages(DebugRequest req) async {
  if (req.method != 'PATCH' && req.method != 'POST') {
    throw BadRequest(
        'method ${req.method} not allowed (PATCH/POST required)');
  }
  Map<String, dynamic> body = const {};
  if (req.body.isNotEmpty) {
    try {
      final parsed = jsonDecode(utf8.decode(req.body));
      if (parsed is Map<String, dynamic>) body = parsed;
    } catch (e) {
      throw BadRequest('invalid JSON body: $e');
    }
  }
  final raw = body['secondary_packages'];
  final pkgs = <String>{};
  if (raw is List) {
    for (final item in raw) {
      final s = item?.toString().trim() ?? '';
      if (s.isNotEmpty) pkgs.add(s);
    }
  }
  final ok = TrafficProfiler.I.updateSecondaryPackages(pkgs);
  if (TrafficProfiler.I.active == null) {
    return JsonResponse({'error': 'no_active_session'}, status: 404);
  }
  return JsonResponse({
    'ok': true,
    'changed': ok,
    'secondary_packages':
        TrafficProfiler.I.active!.secondaryPackages.toList(),
  });
}
