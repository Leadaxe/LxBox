import '../../../controllers/subscription_controller.dart';
import '../../../models/server_list.dart';
import '../../url_mask.dart';

export '../../url_mask.dart' show maskSubscriptionUrl;

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
    // Full detour policy (task 006 — per-server detour toggles).
    // `override_detour` оставлен top-level для backward-compat клиентов,
    // дополнительно группируем в nested object для полного view'а.
    'override_detour': e.overrideDetour,
    'detour_policy': {
      'register_detour_servers': e.registerDetourServers,
      'register_detour_in_auto': e.registerDetourInAuto,
      'use_detour_servers': e.useDetourServers,
      'override_detour': e.overrideDetour,
    },
  };
}
