import '../../contract/errors.dart';
import '../pipeline.dart';

/// Bearer-auth middleware. Пропускает endpoints из [unauthenticatedPaths]
/// (по умолчанию `/ping`) без проверки, остальным требует
/// `Authorization: Bearer <token>`. Пустой конфиг-токен ⇒ 401
/// (сервер не должен быть запущен в таком состоянии, но безопаснее fail-closed).
Middleware auth({
  required String token,
  Set<String> unauthenticatedPaths = const {'/ping'},
}) {
  return (req, ctx, next) async {
    if (unauthenticatedPaths.contains(req.path)) return next();
    if (token.isEmpty) throw const Unauthorized();
    final header = req.header('authorization') ?? '';
    if (header != 'Bearer $token') throw const Unauthorized();
    return next();
  };
}
