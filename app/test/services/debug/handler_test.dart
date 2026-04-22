import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/debug_entry.dart';
import 'package:lxbox/services/app_log.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/logs.dart';
import 'package:lxbox/services/debug/handlers/ping.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';

/// Handler-тесты без platform-зависимостей.
///
/// Покрываем `ping` (pure — использует только `ctx.now()`) и `logs`
/// (использует [AppLog.I] singleton). Handler'ы с `ctx.requireHome()`
/// требовали бы мок `HomeController` — отдельная история, не здесь.
DebugContext _ctx({DateTime? fixedNow, DateTime? startedAt}) =>
    DebugContext(
      registry: DebugRegistry.I,
      appStartedAt: startedAt ?? DateTime.utc(2020, 1, 1, 0, 0, 0),
      clock: fixedNow == null ? null : () => fixedNow,
    );

void main() {
  group('pingHandler', () {
    test('возвращает pong:true + uptime_seconds из injected clock', () async {
      final started = DateTime.utc(2026, 4, 20, 10, 0, 0);
      final now = DateTime.utc(2026, 4, 20, 10, 0, 42);
      final ctx = _ctx(startedAt: started, fixedNow: now);
      final resp = await pingHandler(DebugRequest.forTest(path: '/ping'), ctx);
      expect(resp, isA<JsonResponse>());
      final body = (resp as JsonResponse).body as Map;
      expect(body['pong'], isTrue);
      expect(body['server'], 'lxbox-debug');
      expect(body['uptime_seconds'], 42);
    });
  });

  group('logsHandler', () {
    setUp(() {
      AppLog.I.clear();
      AppLog.I.info('first', source: DebugSource.app);
      AppLog.I.warning('second', source: DebugSource.core);
      AppLog.I.error('third', source: DebugSource.app);
    });

    tearDown(() => AppLog.I.clear());

    test('GET /logs возвращает записи в обратном порядке (новые первые)',
        () async {
      final resp = await logsHandler(
        DebugRequest.forTest(method: 'GET', path: '/logs'),
        _ctx(),
      );
      final list = (resp as JsonResponse).body as List;
      expect(list.length, 3);
      expect(list[0]['message'], 'third');
      expect(list[0]['level'], 'error');
      expect(list[0]['source'], 'app');
      expect(list[1]['message'], 'second');
      expect(list[2]['message'], 'first');
    });

    test('limit ограничивает количество', () async {
      final resp = await logsHandler(
        DebugRequest.forTest(
          method: 'GET',
          path: '/logs',
          query: {'limit': '2'},
        ),
        _ctx(),
      );
      final list = (resp as JsonResponse).body as List;
      expect(list.length, 2);
    });

    test('source=core фильтрует только core entries', () async {
      final resp = await logsHandler(
        DebugRequest.forTest(
          method: 'GET',
          path: '/logs',
          query: {'source': 'core'},
        ),
        _ctx(),
      );
      final list = (resp as JsonResponse).body as List;
      expect(list.length, 1);
      expect(list[0]['source'], 'core');
    });

    test('source=invalid → BadRequest', () async {
      expect(
        () => logsHandler(
          DebugRequest.forTest(
            method: 'GET',
            path: '/logs',
            query: {'source': 'bogus'},
          ),
          _ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
    });

    test('POST /logs/clear очищает AppLog', () async {
      expect(AppLog.I.entries.length, 3);
      final resp = await logsHandler(
        DebugRequest.forTest(method: 'POST', path: '/logs/clear'),
        _ctx(),
      );
      expect(AppLog.I.entries.length, 0);
      final body = (resp as JsonResponse).body as Map;
      expect(body['ok'], isTrue);
    });

    test('q= substring match по message (case-insensitive)', () async {
      final resp = await logsHandler(
        DebugRequest.forTest(
          method: 'GET',
          path: '/logs',
          query: {'q': 'SECOND'},
        ),
        _ctx(),
      );
      final list = (resp as JsonResponse).body as List;
      expect(list.length, 1);
      expect(list[0]['message'], 'second');
    });

    test('level=warning,error фильтрует набор уровней', () async {
      final resp = await logsHandler(
        DebugRequest.forTest(
          method: 'GET',
          path: '/logs',
          query: {'level': 'warning,error'},
        ),
        _ctx(),
      );
      final list = (resp as JsonResponse).body as List;
      expect(list.length, 2);
      expect(list.map((e) => e['level']).toSet(), {'warning', 'error'});
    });

    test('level=bogus → BadRequest', () async {
      expect(
        () => logsHandler(
          DebugRequest.forTest(
            method: 'GET',
            path: '/logs',
            query: {'level': 'bogus'},
          ),
          _ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
    });

    test('q + level + source комбинируются (AND)', () async {
      // 'third' — level=error, source=app → все три фильтра проходит
      final resp = await logsHandler(
        DebugRequest.forTest(
          method: 'GET',
          path: '/logs',
          query: {'q': 'th', 'level': 'error', 'source': 'app'},
        ),
        _ctx(),
      );
      final list = (resp as JsonResponse).body as List;
      expect(list.length, 1);
      expect(list[0]['message'], 'third');
    });

    test('GET /logs/unknown → NotFound', () async {
      expect(
        () => logsHandler(
          DebugRequest.forTest(method: 'GET', path: '/logs/unknown'),
          _ctx(),
        ),
        throwsA(isA<NotFound>()),
      );
    });
  });
}
