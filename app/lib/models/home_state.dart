import 'debug_entry.dart';
import 'tunnel_status.dart';

export 'debug_entry.dart';
export 'tunnel_status.dart';

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

  bool get tunnelUp => tunnel.isUp;

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
    );
  }
}

const _unset = Object();
