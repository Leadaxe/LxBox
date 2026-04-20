import '../context.dart';
import 'request.dart';
import 'response.dart';
import 'router.dart';

/// Продолжение цепочки middleware'ов. Middleware вызывает `next()`
/// чтобы передать управление дальше — или возвращает [DebugResponse]
/// сам чтобы short-circuit'нуть (например, auth fail).
typedef Next = Future<DebugResponse> Function();

/// Middleware — функция-обёртка. Классический onion-chain pattern.
typedef Middleware = Future<DebugResponse> Function(
  DebugRequest req,
  DebugContext ctx,
  Next next,
);

/// Запускает цепочку [middlewares] для запроса, последний слой — [terminal]
/// (обычно [Router.handle]). Возвращает [DebugResponse] — любую ошибку
/// [DebugError] вверх по стеку ловит `errorMapper` middleware (должен
/// стоять первым в списке).
///
/// Порядок middleware'ов — внешний → внутренний:
/// ```
/// [errorMapper, accessLog, hostCheck, auth, timeout]
///  │             │          │          │     └─ last one wraps handler
///  │             │          │          └─ auth (after host check)
///  │             │          └─ host check first (cheap reject)
///  │             └─ measures even for rejected (400/401/403)
///  └─ catches everything below it
/// ```
Future<DebugResponse> runPipeline(
  DebugRequest req,
  DebugContext ctx,
  List<Middleware> middlewares,
  Handler terminal,
) {
  var i = 0;
  Future<DebugResponse> next() {
    if (i >= middlewares.length) return terminal(req, ctx);
    final mw = middlewares[i++];
    return mw(req, ctx, next);
  }

  return next();
}
