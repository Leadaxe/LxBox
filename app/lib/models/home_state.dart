import 'dart:convert';

import 'package:flutter/material.dart';

import '../config/consts.dart';
import '../services/clash_api_client.dart';
import 'debug_entry.dart';
import 'tunnel_status.dart';

export 'debug_entry.dart';
export 'tunnel_status.dart';

enum NodeSortMode {
  defaultOrder('Default', Icons.swap_vert),
  latencyAsc('Ping', Icons.signal_cellular_alt),
  nameAsc('A–Z', Icons.sort_by_alpha);

  const NodeSortMode(this.label, this.icon);
  final String label;
  final IconData icon;

  NodeSortMode get next => NodeSortMode.values[(index + 1) % NodeSortMode.values.length];
}

/// Кэш derived-полей из `configRaw` (outbound proto и detour tags).
/// Парсится **один раз** в `HomeState.copyWith` когда `configRaw` меняется,
/// далее читается O(1) из UI без jsonDecode в itemBuilder'ах.
///
/// Раньше `_buildNodeList` и `StatsScreen._parseDetourMap` парсили config
/// на каждом ребилде ListView — с 50+ нодами это давало заметные аллокации
/// в hot-path'е. Теперь parse один раз при save.
class ConfigCache {
  const ConfigCache.empty()
      : detourTags = const <String>{},
        protoByTag = const <String, String>{};

  /// Control-узлы которые UI не показывает как ноды.
  static const _skipTypes = <String>{
    'selector', 'urltest', 'direct', 'block', 'dns',
  };

  factory ConfigCache.parse(String configRaw) {
    if (configRaw.isEmpty) return const ConfigCache.empty();
    final detourTags = <String>{};
    final protoByTag = <String, String>{};
    try {
      final cfg = jsonDecode(configRaw) as Map<String, dynamic>;
      final outbounds =
          (cfg['outbounds'] as List<dynamic>? ?? <dynamic>[]).whereType<Map<String, dynamic>>();
      final endpoints =
          (cfg['endpoints'] as List<dynamic>? ?? <dynamic>[]).whereType<Map<String, dynamic>>();
      for (final o in [...outbounds, ...endpoints]) {
        final t = o['tag'];
        if (t is! String) continue;
        final d = o['detour'];
        if (d is String && d.isNotEmpty) detourTags.add(t);
        final type = (o['type'] as String?) ?? '';
        if (type.isEmpty || _skipTypes.contains(type)) continue;
        protoByTag[t] = type;
      }
    } catch (_) {
      // malformed JSON — returns empty caches, UI деградирует к placeholder'ам.
    }
    return ConfigCache._(detourTags, protoByTag);
  }

  const ConfigCache._(this.detourTags, this.protoByTag);

  final Set<String> detourTags;
  final Map<String, String> protoByTag;
}

class HomeState {
  HomeState({
    this.configRaw = '',
    ConfigCache? configCache,
    this.tunnel = TunnelStatus.disconnected,
    this.lastError = '',
    this.busy = false,
    this.proxiesJson = const <String, dynamic>{},
    this.groups = const <String>[],
    this.selectedGroup,
    this.nodes = const <String>[],
    this.activeInGroup,
    this.highlightedNode,
    this.lastDelay = const <String, int>{},
    this.pingBusy = const <String, String>{},
    this.debugEvents = const <DebugEntry>[],
    this.sortMode = NodeSortMode.latencyAsc,
    this.traffic = TrafficSnapshot.zero,
    this.connectedSince,
    this.configStaleSinceStart = false,
  }) : configCache = configCache ?? ConfigCache.parse(configRaw);

  final String configRaw;

  /// Derived из `configRaw` — prekомпилированные lookup'ы для UI, чтобы
  /// itemBuilder'ы не делали jsonDecode на каждый rebuild. Пересобирается
  /// в `copyWith` только при смене `configRaw`.
  final ConfigCache configCache;

  final TunnelStatus tunnel;
  final String lastError;
  final bool busy;
  final Map<String, dynamic> proxiesJson;
  final List<String> groups;
  final String? selectedGroup;
  final List<String> nodes;
  final String? activeInGroup;
  final String? highlightedNode;
  final Map<String, int> lastDelay;
  final Map<String, String> pingBusy;
  final List<DebugEntry> debugEvents;
  final NodeSortMode sortMode;
  final TrafficSnapshot traffic;
  final DateTime? connectedSince;
  /// True, если `saveParsedConfig` был вызван при работающем туннеле
  /// с момента его последнего up-перехода. Значит туннель крутит config
  /// старее, чем сохранённый. Сбрасывается на каждом up↔down переходе.
  final bool configStaleSinceStart;

  bool get tunnelUp => tunnel.isUp;

  /// Memoized sort — вычисляется один раз на жизнь этого `HomeState`
  /// инстанса. Новый `copyWith` создаёт новый state → новый late-кэш;
  /// если `nodes`/`sortMode`/`lastDelay` не поменялись между emit'ами,
  /// HomeController всё равно создаст новый state — это отдельная
  /// оптимизация (batched emit). Здесь спасаем от повторного sort
  /// в пределах одного ребилд-цикла виджетов, который обращается к
  /// `sortedNodes` несколько раз (фильтр detour + итерация + builder).
  late final List<String> sortedNodes = _computeSortedNodes();

  List<String> _computeSortedNodes() {
    if (sortMode == NodeSortMode.defaultOrder) return nodes;
    const pinnedOrder = ['direct-out', kAutoOutboundTag];
    final pinned = pinnedOrder.where(nodes.contains).toList();
    final rest = nodes.where((n) => !pinnedOrder.contains(n)).toList();
    switch (sortMode) {
      case NodeSortMode.latencyAsc:
        rest.sort(_compareLatency);
      case NodeSortMode.nameAsc:
        rest.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      case NodeSortMode.defaultOrder:
        break;
    }
    return [...pinned, ...rest];
  }

  int _compareLatency(String a, String b) {
    final da = lastDelay[a];
    final db = lastDelay[b];
    if (da == null && db == null) return 0;
    if (da == null) return 1;
    if (db == null) return -1;
    if (da < 0 && db < 0) return 0;
    if (da < 0) return 1;
    if (db < 0) return -1;
    return da.compareTo(db);
  }

  HomeState copyWith({
    String? configRaw,
    TunnelStatus? tunnel,
    String? lastError,
    bool? busy,
    Map<String, dynamic>? proxiesJson,
    List<String>? groups,
    Object? selectedGroup = _unset,
    List<String>? nodes,
    Object? activeInGroup = _unset,
    Object? highlightedNode = _unset,
    Map<String, int>? lastDelay,
    Map<String, String>? pingBusy,
    List<DebugEntry>? debugEvents,
    NodeSortMode? sortMode,
    TrafficSnapshot? traffic,
    Object? connectedSince = _unset,
    bool? configStaleSinceStart,
  }) {
    return HomeState(
      configRaw: configRaw ?? this.configRaw,
      // ConfigCache пересчитываем ТОЛЬКО при смене configRaw. Иначе шарим
      // тот же immutable объект — скрытая оптимизация: несколько copyWith
      // без configRaw не делают jsonDecode.
      configCache: configRaw != null ? ConfigCache.parse(configRaw) : configCache,
      tunnel: tunnel ?? this.tunnel,
      lastError: lastError ?? this.lastError,
      busy: busy ?? this.busy,
      proxiesJson: proxiesJson ?? this.proxiesJson,
      groups: groups ?? this.groups,
      selectedGroup: identical(selectedGroup, _unset)
          ? this.selectedGroup
          : selectedGroup as String?,
      nodes: nodes ?? this.nodes,
      activeInGroup: identical(activeInGroup, _unset)
          ? this.activeInGroup
          : activeInGroup as String?,
      highlightedNode: identical(highlightedNode, _unset)
          ? this.highlightedNode
          : highlightedNode as String?,
      lastDelay: lastDelay ?? this.lastDelay,
      pingBusy: pingBusy ?? this.pingBusy,
      debugEvents: debugEvents ?? this.debugEvents,
      sortMode: sortMode ?? this.sortMode,
      traffic: traffic ?? this.traffic,
      connectedSince: identical(connectedSince, _unset)
          ? this.connectedSince
          : connectedSince as DateTime?,
      configStaleSinceStart: configStaleSinceStart ?? this.configStaleSinceStart,
    );
  }
}

const _unset = Object();
