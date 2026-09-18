import '../../../models/core_reject_verdict.dart';
import '../../../models/node_warning.dart' show WarningSeverity;
import '../../../models/server_list.dart';
import '../../contract/registry_warning.dart';
import '../../core_reject/core_reject_guard.dart';
import '../../core_reject/core_reject_state.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// Фича 478 — `/core_reject/*`: страховка «узел, который не приняло ядро,
/// выключается сам» целиком наблюдаема и управляема снаружи.
///
/// Почему это API, а не только экраны: единственный способ проверить фичу —
/// довести ядро до отказа на живом устройстве, а дальше нужно ВИДЕТЬ фазу
/// автомата, список выключенного и текст вердикта, и уметь ОТВЕТИТЬ на
/// диалог предела кругов, не трогая экран. Скриншот этого не показывает:
/// плашка говорит «выключено N», а код вердикта и подставленную причину
/// видно только здесь.
///
/// Состояние прогона читается из [CoreRejectState] — сам [CoreRejectGuard]
/// живёт ровно один прогон, снаружи его не удержать.
///
/// Routes:
/// - `GET  /core_reject`                  → фаза автомата + выключенное прогоном
/// - `GET  /core_reject/nodes`            → ВСЕ стоящие вердикты (хранение)
/// - `GET  /core_reject/banner`           → состояние плашки «выключено N»
/// - `POST /core_reject/banner/dismiss`   → закрыть плашку
/// - `GET  /core_reject/prompt`           → висит ли вопрос про предел кругов
/// - `POST /core_reject/prompt?answer=stop|keep` → ответить на него
/// - `POST /core_reject/enable?tag=<tag>` → снять вердикт вручную
/// - `GET  /core_reject/notifications[?tag=<tag>]` → предупреждения узла
///   с кодами и текстами реестра
Future<DebugResponse> coreRejectHandler(
  DebugRequest req,
  DebugContext ctx,
) async {
  return switch (req.path) {
    '/core_reject' => _guardState(req, ctx),
    '/core_reject/nodes' => _nodes(req, ctx),
    '/core_reject/banner' => _banner(req, ctx),
    '/core_reject/banner/dismiss' => _dismissBanner(req, ctx),
    '/core_reject/prompt' => switch (req.method) {
        'GET' => _promptState(req, ctx),
        'POST' => _answerPrompt(req, ctx),
        _ => throw BadRequest(
            'method ${req.method} not allowed on /core_reject/prompt'),
      },
    '/core_reject/enable' => _enable(req, ctx),
    '/core_reject/notifications' => _notifications(req, ctx),
    _ => throw NotFound('core_reject path: ${req.path}'),
  };
}

void _requirePost(DebugRequest req) {
  if (req.method != 'POST') {
    throw BadRequest('${req.path} requires POST, got ${req.method}');
  }
}

String _phaseWire(CoreRejectPhase p) => switch (p) {
      CoreRejectPhase.idle => 'idle',
      CoreRejectPhase.signalStart => 'signal_start',
      CoreRejectPhase.checking => 'checking',
      CoreRejectPhase.awaitingPrompt => 'awaiting_prompt',
      CoreRejectPhase.finalStart => 'final_start',
      CoreRejectPhase.done => 'done',
    };

String _outcomeWire(CoreRejectOutcome o) => switch (o) {
      CoreRejectOutcome.startedClean => 'started_clean',
      CoreRejectOutcome.startedWithDisabled => 'started_with_disabled',
      CoreRejectOutcome.failed => 'failed',
      CoreRejectOutcome.stoppedByUser => 'stopped_by_user',
    };

String _severityWire(WarningSeverity s) => switch (s) {
      WarningSeverity.info => 'info',
      WarningSeverity.warning => 'warning',
      WarningSeverity.error => 'error',
    };

/// `GET /core_reject` — прогон как он есть сейчас. `disabled` — узлы ЭТОГО
/// прогона, а не всё стоящее (для всего стоящего есть `/core_reject/nodes`).
Future<DebugResponse> _guardState(DebugRequest req, DebugContext ctx) async {
  final s = CoreRejectState.I;
  final outcome = s.lastOutcome;
  return JsonResponse({
    'phase': _phaseWire(s.phase),
    'round': s.round,
    'round_limit': kCoreRejectRoundLimit,
    'disabled': [for (final d in s.disabled) d.toJson()],
    'outcome': outcome == null ? null : _outcomeWire(outcome),
    'error': s.lastError,
  });
}

/// `GET /core_reject/nodes` — вердикты, стоящие в ХРАНЕНИИ: переживают
/// перезапуск процесса, в отличие от состояния прогона.
Future<DebugResponse> _nodes(DebugRequest req, DebugContext ctx) async {
  final sub = ctx.requireSub();
  return JsonResponse([
    for (final n in sub.coreRejectedNodes)
      {'source': n.source, 'tag': n.tag, 'reason': n.reason},
  ]);
}

Map<String, Object?> _bannerJson(CoreRejectState s) => {
      'visible': s.bannerVisible,
      'count': s.bannerNodes.length,
      'nodes': [for (final d in s.bannerNodes) d.toJson()],
    };

Future<DebugResponse> _banner(DebugRequest req, DebugContext ctx) async {
  if (req.method != 'GET') {
    throw BadRequest('method ${req.method} not allowed on /core_reject/banner');
  }
  return JsonResponse(_bannerJson(CoreRejectState.I));
}

/// Закрытие плашки идемпотентно: закрыть закрытое — не ошибка, а тот же
/// результат (снаружи гонка «человек успел раньше» неотличима).
Future<DebugResponse> _dismissBanner(DebugRequest req, DebugContext ctx) async {
  _requirePost(req);
  final s = CoreRejectState.I;
  s.dismissBanner();
  return JsonResponse({'ok': true, 'action': 'banner-dismiss', ..._bannerJson(s)});
}

Future<DebugResponse> _promptState(DebugRequest req, DebugContext ctx) async {
  final s = CoreRejectState.I;
  return JsonResponse({
    'pending': s.promptPending,
    'count': s.promptCount,
    'limit': kCoreRejectRoundLimit,
  });
}

/// `POST /core_reject/prompt?answer=stop|keep` — ответ за человека. Без
/// висящего вопроса — 409, а не тихое «ок»: ответ в пустоту значил бы, что
/// автомат ждёт чего-то другого, и проверяющий этого бы не заметил.
Future<DebugResponse> _answerPrompt(DebugRequest req, DebugContext ctx) async {
  final s = CoreRejectState.I;
  if (!s.promptPending) {
    throw const Conflict('no pending prompt');
  }
  // Ответ принимается и запросом, и телом — curl'ом удобнее query.
  final body = req.jsonBodyAsMap();
  final raw = (req.q('answer') ?? body['answer']?.toString() ?? '').trim();
  final answer = switch (raw.toLowerCase()) {
    'stop' => CoreRejectPrompt.stop,
    'keep' || 'keep_checking' => CoreRejectPrompt.keepChecking,
    _ => throw BadRequest('param "answer" must be stop|keep, got "$raw"'),
  };
  s.answerPrompt(answer);
  return JsonResponse({
    'answered': true,
    'answer': answer == CoreRejectPrompt.stop ? 'stop' : 'keep',
  });
}

/// `POST /core_reject/enable?tag=<tag>` — снять вердикт руками (то же, что
/// кнопка плашки). 404 — узла по этому тегу нет; `enabled:false` без 404
/// невозможен, но ключ в ответе оставлен, чтобы форма не зависела от того,
/// какой отказ вернул контроллер.
Future<DebugResponse> _enable(DebugRequest req, DebugContext ctx) async {
  _requirePost(req);
  final body = req.jsonBodyAsMap();
  final tag = (req.q('tag') ?? body['tag']?.toString() ?? '').trim();
  if (tag.isEmpty) {
    throw const BadRequest('param "tag" required');
  }
  final sub = ctx.requireSub();
  final enabled = await sub.enableNodeByCoreTag(tag);
  if (!enabled) throw NotFound('node by core tag: $tag');
  return JsonResponse({'enabled': enabled, 'tag': tag});
}

/// `GET /core_reject/notifications[?tag=<tag>]` — что нарисуют строка и
/// карточка узла: код, severity, подстановки и оба текста реестра. Экран для
/// этого не нужен — и не должен быть нужен: тексты приходят ДАННЫМИ
/// контракта, и проверять надо именно резолв кода, а не вёрстку.
///
/// Без `tag` — карта по всем узлам, у которых хранимые записи есть.
Future<DebugResponse> _notifications(DebugRequest req, DebugContext ctx) async {
  final sub = ctx.requireSub();
  final wanted = req.q('tag')?.trim();

  final byTag = <String, List<StoredWarning>>{};
  for (final e in sub.entries) {
    final list = e.list;
    switch (list) {
      case SubscriptionServers():
        for (final w in list.nodeWarnings.entries) {
          if (w.value.isNotEmpty) byTag[w.key] = w.value;
        }
      case FolderServers():
        for (final m in list.members) {
          if (m.warnings.isEmpty) continue;
          byTag[m.node?.tag ?? m.nameHint] = m.warnings;
        }
      case UserServer():
        if (list.warnings.isEmpty) continue;
        byTag[list.nodes.isEmpty ? list.name : list.nodes.first.tag] =
            list.warnings;
    }
  }

  if (wanted != null && wanted.isNotEmpty) {
    final ws = byTag[wanted];
    if (ws == null) throw NotFound('node by core tag: $wanted');
    return JsonResponse(_renderWarnings(ws));
  }
  return JsonResponse({
    for (final e in byTag.entries) e.key: _renderWarnings(e.value),
  });
}

/// Английский пиненный — machine-поверхность: ответ не должен зависеть от
/// того, какая локаль стоит на устройстве.
List<Map<String, Object?>> _renderWarnings(List<StoredWarning> ws) => [
      for (final w in ws)
        {
          'code': w.code,
          'severity': _severityWire(registrySeverity(w.code)),
          'params': {...w.params},
          'title_en': registryTitle(w.code, RegistryLang.en, params: w.params),
          'text_en': registryText(w.code, RegistryLang.en, params: w.params),
        },
    ];
