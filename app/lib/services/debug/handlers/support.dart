import '../../support/active_time_tracker.dart';
import '../../support/support_message.dart';
import '../../support/support_state.dart';
import '../../version_info.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// §357 — `/support/*`: тестирование support-ленты (§356) без наработки часов.
///
/// - `GET  /support/state`    — сырое `support_state.json` + производные;
/// - `POST /support/reset`    — сброс read/baseline/снуза/кэша
///                              (`?keep_active=false` — обнулить и счётчик);
/// - `POST /support/preview`  — body = JSON ОДНОГО сообщения формата ленты →
///                              немедленный полноэкранный показ ВНЕ гейтов
///                              (пороги/очередь/туннель не проверяются).
///                              `?dry=true` (default) — кнопки работают, но
///                              markRead/snooze НЕ пишутся; `?dry=false` —
///                              пишут (сквозной тест очереди).
///                              `?snooze_hours=N` — snooze_active_hours
///                              синтетической ленты для кнопки «Later» (def 10).
///
/// Показ — паттерн preview-empty-state: `home.requestSupportPreview` +
/// notify → home_screen пушит SupportMessageScreen. Нужен живой UI-процесс.
Future<DebugResponse> supportHandler(DebugRequest req, DebugContext ctx) async {
  return switch ((req.method, req.path)) {
    ('GET', '/support/state') => _state(),
    ('POST', '/support/reset') => _reset(req),
    ('POST', '/support/preview') => _preview(req, ctx),
    _ => throw NotFound('support: ${req.method} ${req.path}'),
  };
}

Future<DebugResponse> _state() async {
  final s = SupportState.I;
  return JsonResponse({
    'app_version': VersionInfo.I.version,
    'total_active_seconds': await ActiveTimeTracker.I.totalSeconds(),
    'state': {
      'active_seconds': await s.getInt('active_seconds'),
      'session_credited': await s.getInt('session_credited'),
      'read': await s.getStringMap('read'),
      'baseline_seconds': await s.getInt('baseline_seconds'),
      'baseline_version': await s.getString('baseline_version'),
      'snooze_after_seconds': await s.getInt('snooze_after_seconds'),
      'cache_json_bytes': (await s.getString('cache_json')).length,
    },
  });
}

/// Сброс решённого (read/baseline/снуз/кэш) — лента начинает с чистого листа.
/// Наработку по умолчанию НЕ трогаем (`keep_active=false` — обнулить и её,
/// вместе с `session_credited`, иначе native-кредит тут же вернёт хвост).
Future<DebugResponse> _reset(DebugRequest req) async {
  final keepActive =
      (req.query['keep_active'] ?? 'true').toLowerCase() != 'false';
  final wiped = <String, Object>{
    'read': <String, String>{},
    'baseline_seconds': 0,
    'baseline_version': '',
    'snooze_after_seconds': 0,
    'cache_json': '',
    if (!keepActive) 'active_seconds': 0,
    if (!keepActive) 'session_credited': 0,
  };
  await SupportState.I.setAll(wiped);
  return JsonResponse({
    'ok': true,
    'action': 'support-reset',
    'kept_active_seconds': keepActive,
  });
}

Future<DebugResponse> _preview(DebugRequest req, DebugContext ctx) async {
  final home = ctx.home;
  if (home == null) throw const Conflict('home controller not ready');
  final message = SupportMessage.fromJson(req.jsonBodyAsMap());
  if (message == null) {
    throw const BadRequest(
        'body must be a feed message object: {"id", "i18n": {"en": {"title", "message", "links"}}}');
  }
  final dry = (req.query['dry'] ?? 'true').toLowerCase() != 'false';
  final snoozeHours = int.tryParse(req.query['snooze_hours'] ?? '') ?? 10;
  home.requestSupportPreview(SupportPreviewRequest(
    feed: SupportFeed(snoozeActiveHours: snoozeHours, messages: [message]),
    message: message,
    dryRun: dry,
  ));
  return JsonResponse({
    'ok': true,
    'action': 'support-preview',
    'id': message.id,
    'dry': dry,
  });
}
