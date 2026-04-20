import '../context.dart';
import '../contract/errors.dart';
import 'request.dart';
import 'response.dart';

/// Типизированный handler: чистая функция от (request, context) в
/// [DebugResponse]. Без side-effects внутри транспорта.
typedef Handler = Future<DebugResponse> Function(
  DebugRequest req,
  DebugContext ctx,
);

/// Префикс-based маршрутизатор. Endpoint регистрируется по префиксу
/// (`/state`), handler получает запрос и сам диспатчит внутри по
/// `/state/subs`, `/state/clash` и т.д. Это проще и меньше магии чем
/// pattern-matching на path-параметры, а handler-файлы уже группируют
/// близкие endpoints.
///
/// При конфликте префиксов побеждает более длинный (longest-prefix-match):
/// `/state/foo` и `/state` — запрос `/state/foo/bar` уйдёт в `/state/foo`.
class Router {
  final List<_Route> _routes = [];

  void mount(String prefix, Handler handler) {
    assert(prefix.startsWith('/'), 'prefix must start with /');
    assert(!prefix.endsWith('/') || prefix == '/', 'prefix must not end with / (except root)');
    _routes.add(_Route(prefix, handler));
  }

  /// Найти handler для path'а или null если не замаунчен.
  Handler? resolve(String path) {
    _Route? best;
    for (final r in _routes) {
      final matches = path == r.prefix || path.startsWith('${r.prefix}/');
      if (!matches) continue;
      if (best == null || r.prefix.length > best.prefix.length) {
        best = r;
      }
    }
    return best?.handler;
  }

  /// Terminal handler для pipeline'а: находит route и вызывает, иначе [NotFound].
  Future<DebugResponse> handle(DebugRequest req, DebugContext ctx) async {
    final h = resolve(req.path);
    if (h == null) throw NotFound('route: ${req.path}');
    return h(req, ctx);
  }
}

class _Route {
  _Route(this.prefix, this.handler);
  final String prefix;
  final Handler handler;
}
