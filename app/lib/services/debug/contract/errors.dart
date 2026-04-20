/// Типизированные ошибки Debug API (§031).
///
/// Handlers/middleware бросают [DebugError]; `errorMapper` middleware
/// перехватывает и рендерит в тело `{"error": {"code": ..., "message": ...}}`
/// со статусом [DebugError.status]. Любой `throw` чего угодно другого
/// попадает в [InternalError] (500) с логированием stack trace — клиенту
/// stack не утекает.
///
/// Контракт не зависит от транспорта: тот же error-set можно отдавать
/// через gRPC/in-process без изменений.
sealed class DebugError implements Exception {
  const DebugError(
    this.message, {
    required this.status,
    required this.code,
  });

  final int status;
  final String code;
  final String message;

  Map<String, Object?> toJson() => {
        'error': {
          'code': code,
          'message': message,
        },
      };

  @override
  String toString() => '$runtimeType($code): $message';
}

/// 400 — невалидный ввод (missing required param, bad format).
class BadRequest extends DebugError {
  const BadRequest(super.message) : super(status: 400, code: 'bad_request');
}

/// 401 — отсутствует/неверный Bearer token.
class Unauthorized extends DebugError {
  const Unauthorized()
      : super(
          'valid Bearer token required',
          status: 401,
          code: 'unauthorized',
        );
}

/// 403 — Host header не `127.0.0.1`/`localhost` (anti-rebinding).
class InvalidHost extends DebugError {
  const InvalidHost()
      : super(
          'request host must be 127.0.0.1 or localhost',
          status: 403,
          code: 'invalid_host',
        );
}

/// 404 — endpoint не найден или ресурс (по id/name) отсутствует.
class NotFound extends DebugError {
  const NotFound(super.message) : super(status: 404, code: 'not_found');
}

/// 409 — pre-condition не выполнен (VPN не поднят, controller не готов,
/// config пустой и т.п.). Юзер может повторить когда state подходит.
class Conflict extends DebugError {
  const Conflict(super.message) : super(status: 409, code: 'conflict');
}

/// 413 — тело запроса превысило `maxBodyBytes`.
class PayloadTooLarge extends DebugError {
  PayloadTooLarge(int limit)
      : super(
          'body exceeds $limit bytes',
          status: 413,
          code: 'payload_too_large',
        );
}

/// 502 — upstream (Clash API, native) вернул ошибку или не ответил.
class UpstreamError extends DebugError {
  const UpstreamError(super.message) : super(status: 502, code: 'upstream_error');
}

/// 504 — handler не уложился в `requestTimeout`.
class RequestTimeout extends DebugError {
  const RequestTimeout()
      : super('request timed out', status: 504, code: 'timeout');
}

/// 500 — необработанное исключение. Сообщение для клиента generic,
/// детали пишем только в AppLog.
class InternalError extends DebugError {
  const InternalError([String? detail])
      : super(
          detail ?? 'internal server error',
          status: 500,
          code: 'internal',
        );
}
