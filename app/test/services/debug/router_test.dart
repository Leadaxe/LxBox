import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/debug/transport/router.dart';

DebugContext _ctx() => DebugContext(
      registry: DebugRegistry.I,
      appStartedAt: DateTime(2020),
    );

Handler _stub(String name) => (req, ctx) async => JsonResponse({'handler': name});

void main() {
  group('Router.resolve', () {
    test('exact prefix match', () {
      final r = Router()..mount('/state', _stub('state'));
      expect(r.resolve('/state'), isNotNull);
      expect(r.resolve('/state/foo'), isNotNull);
    });

    test('не матчит по substring', () {
      final r = Router()..mount('/state', _stub('state'));
      expect(r.resolve('/statemap'), isNull); // `/statemap` != `/state*`
    });

    test('longest-prefix wins', () async {
      final r = Router()
        ..mount('/state', _stub('generic'))
        ..mount('/state/subs', _stub('specific'));
      final h = r.resolve('/state/subs/42');
      final ctx = _ctx();
      final resp = await h!(DebugRequest.forTest(path: '/state/subs/42'), ctx)
          as JsonResponse;
      expect((resp.body as Map)['handler'], 'specific');
    });

    test('несуществующий префикс → null', () {
      final r = Router()..mount('/state', _stub('state'));
      expect(r.resolve('/unknown'), isNull);
    });
  });

  group('Router.handle', () {
    test('404 NotFound если префикс не замаунчен', () async {
      final r = Router()..mount('/state', _stub('state'));
      expect(
        () => r.handle(DebugRequest.forTest(path: '/missing'), _ctx()),
        throwsA(isA<NotFound>()),
      );
    });
  });
}
