import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `/pool` — §208 (SPEC 019 V2) read-only снапшот пула round_robin-группы.
/// Зеркалит UI «View pool» (тот же `HomeController.getPool` → CcChannel.getPool
/// → ядро GetPool RPC). Для отладки балансировщика без UI-попапа.
///
/// Routes:
/// - `GET /pool?tag=<autoTag>` → `{"tag": "...", "slots": [{slot,tag,delay}], "count": N}`
///
/// `tag` — auto-двойник round_robin-канала (напр. `vpn-1-auto`). Не-round_robin
/// группа / туннель down / пул не готов → `slots: []` (не ошибка — у группы
/// просто нет пула). `delay`==0 → нода мёртвая/не измерена.
Future<DebugResponse> poolHandler(DebugRequest req, DebugContext ctx) async {
  if (req.path != '/pool') {
    throw NotFound('pool path: ${req.path}');
  }
  if (req.method != 'GET') {
    throw BadRequest('pool requires GET, got ${req.method}');
  }
  final tag = req.requiredQuery('tag');
  if (tag.isEmpty) throw const BadRequest('"tag" empty');

  final home = ctx.requireHome();
  final slots = await home.getPool(tag);
  return JsonResponse({
    'tag': tag,
    'count': slots.length,
    'slots': [
      for (final s in slots)
        {'slot': s.slot, 'tag': s.tag, 'delay': s.delay, 'alive': s.alive},
    ],
  });
}
