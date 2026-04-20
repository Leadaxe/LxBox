import '../../context.dart';
import '../../contract/errors.dart';
import '../pipeline.dart';
import '../request.dart';
import '../response.dart';

/// Anti-DNS-rebinding. Пускает только запросы, адресованные к
/// `127.0.0.1` или `localhost`. Браузер с rebinded `evil.com` шлёт
/// `Host: evil.com` → 403, даже если токен утёк.
///
/// См. §031 spec, раздел Безопасность, п.6.
Future<DebugResponse> hostCheck(
  DebugRequest req,
  DebugContext ctx,
  Next next,
) async {
  final raw = req.header('host') ?? '';
  final host = raw.split(':').first.toLowerCase();
  if (host != '127.0.0.1' && host != 'localhost') {
    throw const InvalidHost();
  }
  return next();
}
