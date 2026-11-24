import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `/pool` — §208 (SPEC 019 V2) read-only снапшот пула round_robin-группы.
/// Зеркалит UI «View pool» (тот же `HomeController.getPool` → CcChannel.getPool
/// → ядро GetPool RPC). Для отладки балансировщика без UI-попапа.
///
/// Routes:
/// - `GET /pool?tag=<autoTag>` → `{"tag": "...", "count": N, shiftedKeys, markedKeys,
///   frozen, frozenSeconds, "slots": [{slot,tag,delay,alive,quarantined,
///   connections,confirmedFailures}]}`
///
/// `tag` — auto-двойник round_robin-Направления (напр. `vpn-1-auto`). Не-round_robin
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
  final state = await home.getPoolState(tag);
  // §209 — null = CC-клиент недоступен (НЕ пустой пул). Раньше тихо отдавал
  // count:0 неотличимо от «пул пуст» — сбивало диагностику. Теперь явный 409.
  if (state == null) {
    throw const Conflict('cc client unavailable (tunnel down?)');
  }
  return JsonResponse({
    'tag': tag,
    'count': state.slots.length,
    // §759 (ядро SPEC 138) — состояние самовосстановления группы.
    'shiftedKeys': state.shiftedKeys,
    'markedKeys': state.markedKeys,
    'frozen': state.frozen,
    'frozenSeconds': state.frozenSeconds,
    'slots': [
      for (final s in state.slots)
        {
          'slot': s.slot,
          'tag': s.tag,
          'delay': s.delay,
          'alive': s.alive,
          'quarantined': s.quarantined,
          'connections': s.connections,
          'confirmedFailures': s.confirmedFailures,
        },
    ],
  });
}
