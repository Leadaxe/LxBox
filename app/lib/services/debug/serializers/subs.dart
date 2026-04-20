import '../../../controllers/subscription_controller.dart';
import '../../../models/server_list.dart';

/// Маскирует URL подписки — провайдер-credentials живут в path/token
/// части URL (`https://provider/sub/<secret>`). При выдаче в `GET /state/*`
/// по умолчанию светим только `scheme://host/***`. Если клиент явно
/// передал `?reveal=true` — отдаём целиком.
String maskSubscriptionUrl(String raw) {
  if (raw.isEmpty) return '';
  final u = Uri.tryParse(raw);
  if (u == null) return '***';
  if (u.host.isEmpty) return '***';
  return '${u.scheme}://${u.host}/***';
}

/// Одна запись подписки / пользовательского сервера для `/state/subs`.
Map<String, Object?> serializeSubEntry(
  SubscriptionEntry e, {
  required bool reveal,
}) {
  final list = e.list;
  final rawUrl = e.url;
  return {
    'id': e.id,
    'kind': list is SubscriptionServers ? 'SubscriptionServers' : 'UserServer',
    'url': reveal ? rawUrl : maskSubscriptionUrl(rawUrl),
    'title': e.name,
    'enabled': e.enabled,
    'tag_prefix': e.tagPrefix,
    'nodes_count': e.nodeCount,
    'last_update_at': e.lastUpdated?.toUtc().toIso8601String(),
    'last_update_status': e.lastUpdateStatus.name,
    'consecutive_fails': e.consecutiveFails,
    'update_interval_hours': e.updateIntervalHours,
    'override_detour': e.overrideDetour,
  };
}
