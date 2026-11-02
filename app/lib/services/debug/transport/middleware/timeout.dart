import 'dart:async';

import '../../contract/errors.dart';
import '../pipeline.dart';

/// Ограничивает время выполнения handler'а. По истечении —
/// [RequestTimeout] (504). Защита от зависшего Clash API / native
/// plugin'а: handler не блокирует сервер навсегда.
///
/// Сам sing-box может зависнуть на `/group/<tag>/delay` при отсутствии
/// сети — без этого middleware curl повис бы на минуты.
///
/// [perPath] — свой предел для отдельных путей (точное совпадение): §707
/// итер. 5 `POST /taildrop/send` ждёт итога передачи до 60 с.
Middleware timeoutMiddleware(
  Duration limit, {
  Map<String, Duration> perPath = const {},
}) {
  return (req, ctx, next) async {
    try {
      return await next().timeout(perPath[req.path] ?? limit);
    } on TimeoutException {
      throw const RequestTimeout();
    }
  };
}
