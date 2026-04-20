import '../../../models/home_state.dart';

/// [HomeState] → JSON-map для `GET /state`. Ключи в snake_case,
/// timestamps в ISO-8601 UTC. Чувствительных полей нет —
/// всё что в HomeState уже прошло через UI.
Map<String, Object?> serializeHomeState(HomeState s) {
  return {
    'tunnel': s.tunnel.name,
    'tunnel_up': s.tunnelUp,
    'busy': s.busy,
    'config_length': s.configRaw.length,
    'active_in_group': s.activeInGroup,
    'selected_group': s.selectedGroup,
    'highlighted_node': s.highlightedNode,
    'groups': s.groups,
    'nodes_count': s.nodes.length,
    'last_delay': s.lastDelay,
    'ping_busy': s.pingBusy,
    'traffic': {
      'up_total': s.traffic.uploadTotal,
      'down_total': s.traffic.downloadTotal,
      'active_connections': s.traffic.activeConnections,
    },
    'connected_since': s.connectedSince?.toUtc().toIso8601String(),
    'last_error': s.lastError,
    'config_stale_since_start': s.configStaleSinceStart,
    'sort_mode': s.sortMode.name,
  };
}
