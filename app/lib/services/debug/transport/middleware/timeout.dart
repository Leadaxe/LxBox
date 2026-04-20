import 'dart:async';

import '../../contract/errors.dart';
import '../pipeline.dart';

/// Ограничивает время выполнения handler'а. По истечении —
/// [RequestTimeout] (504). Защита от зависшего Clash API / native
/// plugin'а: handler не блокирует сервер навсегда.
///
/// Сам sing-box может зависнуть на `/group/<tag>/delay` при отсутствии
/// сети — без этого middleware curl повис бы на минуты.
Middleware timeoutMiddleware(Duration limit) {
  return (req, ctx, next) async {
    try {
      return await next().timeout(limit);
    } on TimeoutException {
      throw const RequestTimeout();
    }
  };
}
