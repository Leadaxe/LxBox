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

class HomeState {
  const HomeState({
    this.configRaw = '',
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
  });

  final String configRaw;
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

  List<String> get sortedNodes {
    if (sortMode == NodeSortMode.defaultOrder) return nodes;
    const pinnedOrder = ['direct-out', kAutoOutboundTag];
    final pinned = pinnedOrder.where(nodes.contains).toList();
    final rest = nodes.where((n) => !pinnedOrder.contains(n)).toList();
    switch (sortMode) {
      case NodeSortMode.latencyAsc:
        rest.sort((a, b) => _compareLatency(a, b));
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
