import 'dart:async';

import 'package:flutter/services.dart';

/// §669 — Dart-двойник `ProbeSession.kt` для тестов: владелец сессии (runId),
/// «stale run» на чужой id, `probeCancel` обрывает начатые замеры, новый
/// `probeStart` закрывает старую сессию. Замеры по умолчанию висят (dial не
/// возвращается), пока их не отпустит отмена, закрытие сессии или тест.
class FakeProbeSession {
  final calls = <MethodCall>[];

  int _nextId = 0;
  int? live;
  bool _liveCancelled = false;

  /// Замер живой сессии висит, пока его не отпустят.
  bool holdUrlTests = true;
  final _pending = <Completer<Map<String, Object>>>[];
  int get pendingCount => _pending.length;

  /// Не-null — `probeStop` своей сессии ждёт его (долгий `closeService`).
  Completer<void>? stopGate;

  int callsOf(String method) => calls.where((c) => c.method == method).length;

  List<int> runIdsOf(String method) => [
        for (final c in calls)
          if (c.method == method) (c.arguments as Map)['runId'] as int,
      ];

  /// Отпустить висящие замеры успехом.
  void releaseOk({int delay = 50}) =>
      _release({'delay': delay, 'error': ''});

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = (call.arguments as Map?) ?? const {};
    final runId = (args['runId'] as int?) ?? 0;
    switch (call.method) {
      case 'probeStart':
        _closeLive();
        live = ++_nextId;
        _liveCancelled = false;
        return {'error': '', 'runId': live};
      case 'probeUrlTest':
        if (live == null) {
          return {'delay': 0, 'error': 'probe session not running'};
        }
        if (runId != live) return {'delay': 0, 'error': 'stale run'};
        if (_liveCancelled) return {'delay': 0, 'error': 'probe run cancelled'};
        if (!holdUrlTests) return {'delay': 50, 'error': ''};
        final c = Completer<Map<String, Object>>();
        _pending.add(c);
        return c.future;
      case 'probeCancel':
        if (runId == live) {
          _liveCancelled = true;
          _release({'delay': 0, 'error': 'context canceled'});
        }
        return null;
      case 'probeStop':
        if (live != null && runId != live) return null; // stale → no-op
        final gate = stopGate;
        if (gate != null) await gate.future;
        _closeLive();
        return null;
    }
    return null;
  }

  void _closeLive() {
    _release({'delay': 0, 'error': 'probe session closed'});
    live = null;
  }

  void _release(Map<String, Object> r) {
    final list = List.of(_pending);
    _pending.clear();
    for (final c in list) {
      c.complete(r);
    }
  }
}
