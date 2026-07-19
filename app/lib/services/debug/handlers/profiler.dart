// §044 / §048 — Debug API handler for `/profiler/*` (system-wide only, §288).
//
//   §048 inclusive observer:
//   GET    /profiler/live?seconds=60     — global rolling buffer snapshot
//   GET    /profiler/live/stream         — SSE stream of all events system-wide
//   GET    /profiler/live/unattributed   — recent unattributed (DNS fail без owner etc)
//   POST   /profiler/live/start          — startGlobalRecording
//   POST   /profiler/live/stop           — stopGlobalRecording
//   GET    /profiler/live/state          — recording state + counts

import '../../traffic_profiler.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

Future<DebugResponse> profilerHandler(
    DebugRequest req, DebugContext ctx) async {
  final path = req.path;
  return switch (path) {
    '/profiler/live' => _live(req),
    '/profiler/live/stream' => _liveStream(req),
    '/profiler/live/unattributed' => _liveUnattributed(req),
    '/profiler/live/start' => _liveStart(req),
    '/profiler/live/stop' => _liveStop(req),
    '/profiler/live/state' => _liveState(req),
    _ => throw NotFound('profiler path: $path'),
  };
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

Future<DebugResponse> _liveStart(DebugRequest req) async {
  if (req.method != 'POST') {
    throw BadRequest('method ${req.method} not allowed (POST required)');
  }
  TrafficProfiler.I.startGlobalRecording();
  return JsonResponse({
    'ok': true,
    'recording': true,
    'started_at':
        TrafficProfiler.I.globalRecordingStartedAt?.toUtc().toIso8601String(),
  });
}

Future<DebugResponse> _liveStop(DebugRequest req) async {
  if (req.method != 'POST') {
    throw BadRequest('method ${req.method} not allowed (POST required)');
  }
  TrafficProfiler.I.stopGlobalRecording();
  return JsonResponse({'ok': true, 'recording': false});
}

Future<DebugResponse> _liveState(DebugRequest req) async {
  if (req.method != 'GET') {
    throw BadRequest('method ${req.method} not allowed (GET required)');
  }
  return JsonResponse({
    'recording': TrafficProfiler.I.isGlobalRecording,
    'started_at':
        TrafficProfiler.I.globalRecordingStartedAt?.toUtc().toIso8601String(),
    'buffer_count': TrafficProfiler.I.globalRollingBuffer.length,
    'unattributed_count': TrafficProfiler.I.recentUnattributedCount,
    'banner_active': TrafficProfiler.I.unattributedBannerActive,
  });
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
