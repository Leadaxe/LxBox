import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/transport/middleware/auth.dart';
import 'package:lxbox/services/debug/transport/middleware/error_mapper.dart';
import 'package:lxbox/services/debug/transport/middleware/host_check.dart';
import 'package:lxbox/services/debug/transport/middleware/timeout.dart';
import 'package:lxbox/services/debug/transport/pipeline.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';

DebugContext _ctx() => DebugContext(
      registry: DebugRegistry.I,
      appStartedAt: DateTime(2020),
    );

Future<DebugResponse> _okHandler(DebugRequest r, DebugContext c) async =>
    const JsonResponse({'ok': true});

DebugRequest _req({
  String path = '/state',
  String host = '127.0.0.1',
  String? auth,
}) =>
    DebugRequest.forTest(
      path: path,
      headers: {
        'host': host,
        'authorization': ?auth,
      },
    );

void main() {
  group('hostCheck middleware', () {
    test('localhost пропускает', () async {
      final resp = await runPipeline(
        _req(host: 'localhost'),
        _ctx(),
        [hostCheck],
        _okHandler,
      );
      expect(resp.status, 200);
    });

    test('127.0.0.1 пропускает', () async {
      final resp = await runPipeline(
        _req(host: '127.0.0.1'),
        _ctx(),
        [hostCheck],
        _okHandler,
      );
      expect(resp.status, 200);
    });

    test('evil.com → InvalidHost', () async {
      expect(
        () => runPipeline(_req(host: 'evil.com'), _ctx(), [hostCheck], _okHandler),
        throwsA(isA<InvalidHost>()),
      );
    });

    test('игнорирует регистр', () async {
      final resp = await runPipeline(
        _req(host: 'LOCALHOST'),
        _ctx(),
        [hostCheck],
        _okHandler,
      );
      expect(resp.status, 200);
    });

    test('отбрасывает port из header', () async {
      // `Host: 127.0.0.1:9269` — корректный.
      final resp = await runPipeline(
        _req(host: '127.0.0.1:9269'),
        _ctx(),
        [hostCheck],
        _okHandler,
      );
      expect(resp.status, 200);
    });
  });

  group('auth middleware', () {
    final mw = auth(token: 'secret-token', unauthenticatedPaths: {'/ping'});

    test('валидный токен пропускает', () async {
      final resp = await runPipeline(
        _req(auth: 'Bearer secret-token'),
        _ctx(),
        [mw],
        _okHandler,
      );
      expect(resp.status, 200);
    });

    test('неверный токен → Unauthorized', () async {
      expect(
        () => runPipeline(
          _req(auth: 'Bearer wrong'),
          _ctx(),
          [mw],
          _okHandler,
        ),
        throwsA(isA<Unauthorized>()),
      );
    });

    test('нет header → Unauthorized', () async {
      expect(
        () => runPipeline(_req(), _ctx(), [mw], _okHandler),
        throwsA(isA<Unauthorized>()),
      );
    });

    test('/ping пропускает без auth', () async {
      final resp = await runPipeline(
        _req(path: '/ping'),
        _ctx(),
        [mw],
        _okHandler,
      );
      expect(resp.status, 200);
    });

    test('пустой token → Unauthorized даже с Bearer', () async {
      final emptyMw = auth(token: '');
      expect(
        () => runPipeline(
          _req(auth: 'Bearer '),
          _ctx(),
          [emptyMw],
          _okHandler,
        ),
        throwsA(isA<Unauthorized>()),
      );
    });

    test('схема должна быть именно `Bearer `, не `bearer`', () async {
      // HTTP-заголовки case-insensitive по имени, но не по значению.
      expect(
        () => runPipeline(
          _req(auth: 'bearer secret-token'),
          _ctx(),
          [mw],
          _okHandler,
        ),
        throwsA(isA<Unauthorized>()),
      );
    });
  });

  group('errorMapper middleware', () {
    test('DebugError → ErrorResponse с правильным статусом', () async {
      Future<DebugResponse> failing(DebugRequest r, DebugContext c) async {
        throw const NotFound('nope');
      }

      final resp = await runPipeline(_req(), _ctx(), [errorMapper], failing);
      expect(resp, isA<ErrorResponse>());
      expect(resp.status, 404);
    });

    test('обычный exception → InternalError (500)', () async {
      Future<DebugResponse> boom(DebugRequest r, DebugContext c) async {
        throw StateError('oops');
      }

      final resp = await runPipeline(_req(), _ctx(), [errorMapper], boom);
      expect(resp, isA<ErrorResponse>());
      expect(resp.status, 500);
    });

    test('успешный handler проходит через', () async {
      final resp =
          await runPipeline(_req(), _ctx(), [errorMapper], _okHandler);
      expect(resp.status, 200);
    });
  });

  group('timeout middleware', () {
    test('быстрый handler проходит', () async {
      final resp = await runPipeline(
        _req(),
        _ctx(),
        [timeoutMiddleware(const Duration(seconds: 1))],
        _okHandler,
      );
      expect(resp.status, 200);
    });

    test('долгий handler → RequestTimeout', () async {
      Future<DebugResponse> slow(DebugRequest r, DebugContext c) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return const JsonResponse({'ok': true});
      }

      expect(
        () => runPipeline(
          _req(),
          _ctx(),
          [timeoutMiddleware(const Duration(milliseconds: 10))],
          slow,
        ),
        throwsA(isA<RequestTimeout>()),
      );
    });
  });

  group('pipeline composition', () {
    test('middleware выполняются в порядке, каждый видит результат следующего',
        () async {
      final trace = <String>[];
      Middleware logOrder(String name) =>
          (req, ctx, next) async {
            trace.add('$name-before');
            final r = await next();
            trace.add('$name-after');
            return r;
          };

      Future<DebugResponse> h(DebugRequest r, DebugContext c) async {
        trace.add('handler');
        return const JsonResponse({});
      }

      await runPipeline(
        _req(),
        _ctx(),
        [logOrder('A'), logOrder('B'), logOrder('C')],
        h,
      );

      expect(trace, [
        'A-before',
        'B-before',
        'C-before',
        'handler',
        'C-after',
        'B-after',
        'A-after',
      ]);
    });

    test('middleware может short-circuit — next() не вызывается', () async {
      var handlerCalled = false;
      Future<DebugResponse> shortCircuit(req, ctx, next) async {
        return const JsonResponse({'short': true}, status: 418);
      }

      Future<DebugResponse> h(DebugRequest r, DebugContext c) async {
        handlerCalled = true;
        return const JsonResponse({});
      }

      final resp = await runPipeline(_req(), _ctx(), [shortCircuit], h);
      expect(resp.status, 418);
      expect(handlerCalled, isFalse);
    });
  });
}
