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
    // §311 — длина снапшота работающего ядра (GET /config/running); null =
    // недоступен (туннель down / старое ядро / ещё не подтянут). Вместе с
    // config_length показывает сам факт расхождения running vs saved.
    'running_config_length': s.runningConfigRaw?.length,
    'active_in_group': s.activeInGroup,
    'selected_group': s.selectedGroup,
    'highlighted_node': s.highlightedNode,
    'groups': s.groups,
    'nodes_count': s.nodes.length,
    // §325 — замеры разложены по Направлениям (`Направление → тег → ms`); ключ
    // `' scratch'` = замеры вне выбранного Направления. `last_delay` — плоский срез
    // ТЕКУЩЕГО Направления с фоллбэком, ровно то, что видно в списке.
    // §393 A2 — было `delay_by_channel`; dev-only JSON, алиас не заводим.
    'delay_by_direction': s.delayByDirection,
    'last_delay': {
      for (final tag in s.nodes)
        if (s.delayOf(tag) != null) tag: s.delayOf(tag),
    },
    'ping_busy': s.pingBusy,
    'traffic': {
      'up_total': s.traffic.uploadTotal,
      'down_total': s.traffic.downloadTotal,
      'active_connections': s.traffic.activeConnections,
    },
    'connected_since': s.connectedSince?.toUtc().toIso8601String(),
    'last_error': s.lastError?.renderEn() ?? '',
    // §250 — причина последнего аварийного стопа/revoke; в отличие от
    // last_error не расходуется UI, чистится только успешным стартом.
    // In-memory — пусто после рестарта процесса.
    'last_start_error': s.lastStartError,
    'last_start_error_at': s.lastStartErrorAt?.toUtc().toIso8601String(),
    // §076 renamed from `config_stale_since_start`.
    'config_changed_need_restart': s.configChangedNeedRestart,
    'sort_mode': s.sortMode.name,
    // §070 / §071 — sort options + manual mode state. Non-breaking add.
    'pin_direct': s.pinDirect,
    'pin_auto': s.pinAuto,
    'resort_on_manual_ping': s.resortOnManualPing,
    'ping_batch_gen': s.pingBatchGen,
    'manual_order': s.manualOrder,
  };
}
