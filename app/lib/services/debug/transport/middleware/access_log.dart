import '../../contract/errors.dart';
import '../pipeline.dart';
import '../response.dart';

/// Структурный лог на каждый запрос: метод, path, query (с redaction
/// sensitive-ключей), статус, latency, ошибка если была.
///
/// Пример строки:
/// ```
/// [debug-api] GET /state?reveal=*** → 200 12ms
/// [debug-api] POST /action/toast?msg=hi → 200 3ms
/// [debug-api] GET /state → 401 1ms
/// ```
///
/// Ставится **после** errorMapper: тогда logging видит финальный
/// статус (включая 401/403/500), а не сырое исключение.
Middleware accessLog() {
  return (req, ctx, next) async {
    final sw = Stopwatch()..start();
    DebugResponse? resp;
    Object? thrown;
    try {
      resp = await next();
      return resp;
    } catch (e) {
      thrown = e;
      rethrow;
    } finally {
      sw.stop();
      final status = resp?.status ??
          (thrown is DebugError ? thrown.status : 500);
      final queryStr = _formatQuery(req.query);
      final line = '[debug-api] ${req.method} ${req.path}'
          '${queryStr.isEmpty ? '' : '?$queryStr'}'
          ' → $status ${sw.elapsedMilliseconds}ms';
      if (status >= 500) {
        ctx.log.warning(line);
      } else {
        ctx.log.debug(line);
      }
    }
  };
}

/// Redact'им sensitive query-ключи (`token`, `secret`, `auth`, `key`).
/// Значения заменяются на `***`; ключ оставляем чтобы видеть структуру.
String _formatQuery(Map<String, String> q) {
  if (q.isEmpty) return '';
  return q.entries.map((e) {
    final v = _isSensitive(e.key) ? '***' : e.value;
    return '${e.key}=$v';
  }).join('&');
}

bool _isSensitive(String key) {
  final k = key.toLowerCase();
  return k.contains('token') ||
      k.contains('secret') ||
      k.contains('auth') ||
      k == 'key';
}
