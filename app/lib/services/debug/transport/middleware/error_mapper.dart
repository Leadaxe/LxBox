import '../../context.dart';
import '../../contract/errors.dart';
import '../pipeline.dart';
import '../request.dart';
import '../response.dart';

/// Ловит все [DebugError] из handler'ов/middleware'ов и рендерит
/// в [ErrorResponse]. Незнакомые исключения — в [InternalError] (500)
/// с логированием stack trace; клиент получает generic "internal server
/// error" без leak'а деталей.
///
/// Должен стоять **первым** в pipeline'е — иначе исключения внешних
/// middleware (например, accessLog падает на форматировании) вылетят
/// наружу неперехваченными.
Future<DebugResponse> errorMapper(
  DebugRequest req,
  DebugContext ctx,
  Next next,
) async {
  try {
    return await next();
  } on DebugError catch (e) {
    return ErrorResponse(e);
  } catch (e, st) {
    ctx.log.error(
      'Debug API: unhandled ${req.method} ${req.path} — $e\n$st',
    );
    return ErrorResponse(InternalError('$e'));
  }
}
