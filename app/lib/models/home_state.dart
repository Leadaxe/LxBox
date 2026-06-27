import 'package:flutter/material.dart';

import '../config/consts.dart';
import '../vpn/cc_channel.dart';
import 'config_node.dart';
import 'debug_entry.dart';
import 'traffic_snapshot.dart';
import 'tunnel_status.dart';

export 'config_node.dart';
export 'traffic_snapshot.dart';

export 'debug_entry.dart';
export 'tunnel_status.dart';

enum NodeSortMode {
  defaultOrder('Default', Icons.swap_vert),
  latencyAsc('Ping', Icons.signal_cellular_alt),
  nameAsc('A–Z', Icons.sort_by_alpha),
  // §071/§100 — manual («Custom»). Теперь ВХОДИТ в tap-cycle (carousel, см.
  // `next`) И выбирается из sort-меню; активируется выбором/cycle ИЛИ drag'ом.
  manual('Custom', Icons.drag_indicator);

  const NodeSortMode(this.label, this.icon);
  final String label;
  final IconData icon;

  /// §100: cycle включает все 4 режима (carousel) —
  /// default → ping → A–Z → Custom(manual) → default.
  NodeSortMode get next => switch (this) {
        NodeSortMode.defaultOrder => NodeSortMode.latencyAsc,
        NodeSortMode.latencyAsc => NodeSortMode.nameAsc,
        NodeSortMode.nameAsc => NodeSortMode.manual,
        NodeSortMode.manual => NodeSortMode.defaultOrder,
      };
}

class HomeState {
  HomeState({
    this.configRaw = '',
    ParsedConfig? configModel,
    this.tunnel = TunnelStatus.disconnected,
    this.lastError = '',
    this.busy = false,
    this.ccGroups = const <CcGroup>[],
    this.groups = const <String>[],
    this.groupLabels = const <String, String>{},
    this.selectedGroup,
    this.nodes = const <String>[],
    this.activeInGroup,
    this.highlightedNode,
    this.lastDelay = const <String, int>{},
    this.pingBusy = const <String, String>{},
    this.debugEvents = const <DebugEntry>[],
    this.sortMode = NodeSortMode.latencyAsc,
    // §070 — sort options (per-session, defaults = old behaviour bit-exact).
    this.pinDirect = true,
    this.pinAuto = true,
    this.resortOnManualPing = true,
    // §070 — passive counter, bump'ается на batch ping finish / group switch /
    // config rebuild. Используется UI-cache (_HomeScreenState._viewSortedNodes)
    // для frozen sort при resortOnManualPing=false.
    this.pingBatchGen = 0,
    // §071 — manual reorder (per-session). Empty = mode неактивен или не настроен.
    this.manualOrder = const <String>[],
    this.traffic = TrafficSnapshot.zero,
    this.connectedSince,
    this.configChangedNeedRestart = false,
    this.configLoadError = false,
  }) : configModel = configModel ?? ParsedConfig.parse(configRaw);

  final String configRaw;

  /// §091 — распарсенный конфиг (`Map<tag, ConfigNode>` + структурные
  /// запросы). Статик-слой: пересобирается в `copyWith` ТОЛЬКО при смене
  /// `configRaw`; пинги/active/urltest живут в отдельных динамик-map'ах.
  final ParsedConfig configModel;

  final TunnelStatus tunnel;
  final String lastError;
  final bool busy;

  /// §122 — снапшот дерева групп из libbox CommandClient (`CcChannel.groups`).
  /// Источник истины для групп/нод/active-выбора (заменил Clash `proxiesJson`).
  final List<CcGroup> ccGroups;
  final List<String> groups;

  /// §125 — tag→label каналов (из storage `channels[]`). Для отображения
  /// человекочитаемого имени канала в home-dropdown вместо tag ('vpn-1').
  final Map<String, String> groupLabels;

  /// Человекочитаемое имя группы: label канала из storage, иначе сам tag.
  String groupLabelOf(String tag) => groupLabels[tag] ?? tag;

  final String? selectedGroup;
  final List<String> nodes;
  final String? activeInGroup;
  final String? highlightedNode;
  final Map<String, int> lastDelay;
  final Map<String, String> pingBusy;
  final List<DebugEntry> debugEvents;
  final NodeSortMode sortMode;
  /// §070 — pin direct/auto в pinned section при non-default sort.
  /// `defaultOrder` mode игнорирует pin (см. `_computeSortedNodes`).
  final bool pinDirect;
  final bool pinAuto;
  /// §070 — pересчитывать sort при manual `runNodeUrltest` (single tag delay
  /// update). False → UI-cache держит frozen sort до `pingBatchGen` bump.
  final bool resortOnManualPing;
  /// §070 — counter, bumped в HomeController на mass URLtest finish /
  /// runGroupUrltest / group switch / config rebuild. Pure UI-cache signal,
  /// в `_computeSortedNodes` не используется.
  final int pingBatchGen;
  /// §071 — user-defined order для `NodeSortMode.manual`. Empty = mode
  /// неактивен или не настроен. Filtering: `manualOrder.where(nodes.contains)`
  /// + новые ноды (subscription update) в конце.
  final List<String> manualOrder;
  final TrafficSnapshot traffic;
  final DateTime? connectedSince;
  /// §076 (rename from `configStaleSinceStart`): True, если `saveParsedConfig`
  /// был вызван при работающем туннеле — running config теперь устарел
  /// относительно saved, нужен restart чтобы native перечитал.
  /// Sticky in-memory flag, сбрасывается на каждом успешном `_startInternal`.
  final bool configChangedNeedRestart;

  /// §116 — на старте `getConfig()` не вернул конфиг (`configRaw` пустой) ПРИ
  /// живом туннеле: файл не прочёлся, но туннель уже несёт рабочий конфиг.
  /// Аномалия загрузки → постоянный error-баннер «Config loading error» с
  /// рестартом. Гаснет, когда `configRaw` стал непустым (load/save). Не
  /// пересобираем (см. bootstrap split).
  final bool configLoadError;

  bool get tunnelUp => tunnel.isUp;

  // ─────────────── §122 — типизированный доступ к ccGroups ───────────────
  // Чистые методы на нативных CommandClient-моделях (заменили статические
  // хелперы `ClashApiClient.selectorGroupTags`/`urltestNow`/`proxyEntry`).

  /// Группа по тегу (`null` если нет). Группа-аутбаунд = selector/urltest.
  CcGroup? groupOf(String tag) {
    for (final g in ccGroups) {
      if (g.tag == tag) return g;
    }
    return null;
  }

  bool _isUrltest(String type) => type.toLowerCase().contains('urltest');
  bool _isSelector(String type) => type.toLowerCase().contains('selector');

  /// Теги selector-групп (для dropdown'а выбора). URLTest-группы НЕ включаются
  /// (выбор в них автоматический). `selectable` от ядра = ровно selector'ы.
  List<String> get selectorGroupTags => [
        for (final g in ccGroups)
          if (g.selectable && _isSelector(g.type)) g.tag,
      ];

  /// Для urltest-группы — её авто-выбранный член (`selected`). Для не-urltest
  /// или отсутствующей — `null`. Заменяет `ClashApiClient.urltestNow`.
  String? urltestNowOf(String tag) {
    final g = groupOf(tag);
    if (g == null || !_isUrltest(g.type)) return null;
    return g.selected.isEmpty ? null : g.selected;
  }

  /// §078 — control-outbound (selector/urltest/direct/block/dns), не payload-нода.
  /// Caller'ы короткозамыкают такие теги в matching (всегда видны) и исключают
  /// из 'Custom'-chip detection. Источник: дерево групп (selector/urltest) +
  /// `ConfigNode.isControl` из распарсенного конфига (direct/block/dns).
  bool isControlTag(String tag) {
    final g = groupOf(tag);
    if (g != null && (_isSelector(g.type) || _isUrltest(g.type))) return true;
    return configModel[tag]?.isControl ?? false;
  }

  /// Все urltest-группы (для форс-URLTest после mass-ping, §070).
  Iterable<CcGroup> get urltestGroups =>
      ccGroups.where((g) => _isUrltest(g.type));

  /// Memoized sort — вычисляется один раз на жизнь этого `HomeState`
  /// инстанса. Новый `copyWith` создаёт новый state → новый late-кэш;
  /// если `nodes`/`sortMode`/`lastDelay` не поменялись между emit'ами,
  /// HomeController всё равно создаст новый state — это отдельная
  /// оптимизация (batched emit). Здесь спасаем от повторного sort
  /// в пределах одного ребилд-цикла виджетов, который обращается к
  /// `sortedNodes` несколько раз (фильтр detour + итерация + builder).
  late final List<String> sortedNodes = _computeSortedNodes();

  List<String> _computeSortedNodes() {
    // §070: pinDirect/pinAuto управляют наполнением pinned section во
    // ВСЕХ modes включая `defaultOrder`. Default = pristine config order
    // для non-pinned части, но pinned всегда сверху если toggle ON.
    final pinnedOrder = <String>[
      if (pinDirect) 'direct-out',
      if (pinAuto) kAutoOutboundTag,
    ];
    final pinned = pinnedOrder.where(nodes.contains).toList();
    final rest = nodes.where((n) => !pinnedOrder.contains(n)).toList();
    switch (sortMode) {
      case NodeSortMode.defaultOrder:
        // rest в pristine config order (без сортировки).
        break;
      case NodeSortMode.latencyAsc:
        rest.sort(_compareLatency);
      case NodeSortMode.nameAsc:
        rest.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      case NodeSortMode.manual:
        // §071: manualOrder filtered к present nodes + новые ноды
        // (subscription update / add server) в конец.
        final restSet = rest.toSet();
        final ordered = <String>[
          ...manualOrder.where(restSet.contains),
          ...rest.where((n) => !manualOrder.contains(n)),
        ];
        return [...pinned, ...ordered];
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
    List<CcGroup>? ccGroups,
    List<String>? groups,
    Map<String, String>? groupLabels,
    Object? selectedGroup = _unset,
    List<String>? nodes,
    Object? activeInGroup = _unset,
    Object? highlightedNode = _unset,
    Map<String, int>? lastDelay,
    Map<String, String>? pingBusy,
    List<DebugEntry>? debugEvents,
    NodeSortMode? sortMode,
    bool? pinDirect,
    bool? pinAuto,
    bool? resortOnManualPing,
    int? pingBatchGen,
    List<String>? manualOrder,
    TrafficSnapshot? traffic,
    Object? connectedSince = _unset,
    bool? configChangedNeedRestart,
    bool? configLoadError,
  }) {
    return HomeState(
      configRaw: configRaw ?? this.configRaw,
      // configModel пересчитываем ТОЛЬКО при смене configRaw. Иначе шарим
      // тот же immutable объект — несколько copyWith без configRaw не
      // делают jsonDecode.
      configModel:
          configRaw != null ? ParsedConfig.parse(configRaw) : configModel,
      tunnel: tunnel ?? this.tunnel,
      lastError: lastError ?? this.lastError,
      busy: busy ?? this.busy,
      ccGroups: ccGroups ?? this.ccGroups,
      groups: groups ?? this.groups,
      groupLabels: groupLabels ?? this.groupLabels,
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
      pinDirect: pinDirect ?? this.pinDirect,
      pinAuto: pinAuto ?? this.pinAuto,
      resortOnManualPing: resortOnManualPing ?? this.resortOnManualPing,
      pingBatchGen: pingBatchGen ?? this.pingBatchGen,
      manualOrder: manualOrder ?? this.manualOrder,
      traffic: traffic ?? this.traffic,
      connectedSince: identical(connectedSince, _unset)
          ? this.connectedSince
          : connectedSince as DateTime?,
      configChangedNeedRestart: configChangedNeedRestart ?? this.configChangedNeedRestart,
      configLoadError: configLoadError ?? this.configLoadError,
    );
  }
}

const _unset = Object();
