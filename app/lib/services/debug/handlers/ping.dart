import '../context.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `GET /ping` — health-check. Без auth.
///
/// Минимальный ответ: сервер жив, сколько секунд аптайм. Версия приложения
/// и build-info отдаются в `GET /device`.
Future<DebugResponse> pingHandler(DebugRequest req, DebugContext ctx) async {
  final uptime = ctx.now().difference(ctx.appStartedAt).inSeconds;
  return JsonResponse({
    'pong': true,
    'server': 'lxbox-debug',
    'uptime_seconds': uptime,
  });
}
