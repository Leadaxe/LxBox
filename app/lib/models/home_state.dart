import 'package:flutter/material.dart';

import '../vpn/cc_channel.dart';
import 'config_node.dart';
import 'debug_entry.dart';
import 'dependency_graph.dart';
import 'stop_reason.dart';
import 'traffic_snapshot.dart';
import 'tunnel_status.dart';
import 'ui_msg.dart';
import '../services/l10n/locale_controller.dart';

export 'config_node.dart';
export 'dependency_graph.dart';
export 'stop_reason.dart';
export 'traffic_snapshot.dart';
export 'ui_msg.dart';

export 'debug_entry.dart';
export 'tunnel_status.dart';

enum NodeSortMode {
  defaultOrder(Icons.swap_vert),
  latencyAsc(Icons.signal_cellular_alt),
  nameAsc(Icons.sort_by_alpha),
  // §071/§100 — manual («Custom»). Теперь ВХОДИТ в tap-cycle (carousel, см.
  // `next`) И выбирается из sort-меню; активируется выбором/cycle ИЛИ drag'ом.
  manual(Icons.drag_indicator);

  const NodeSortMode(this.icon);
  final IconData icon;

  /// §279 — display-label режима (рендер по локали в момент показа).
  /// Персист/Debug API используют `.name` (wire), не label.
  String label() => switch (this) {
        defaultOrder => getLocalText.s("Default"),
        latencyAsc => getLocalText.s("Ping"),
        nameAsc => getLocalText.s("A–Z"),
        manual => getLocalText.s("Custom"),
      };

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
    this.runningConfigRaw,
    ParsedConfig? configModel,
    ParsedConfig? runningModel,
    this.tunnel = TunnelStatus.disconnected,
    this.lastError,
    this.stopReason,
    this.busy = false,
    this.ccGroups = const <CcGroup>[],
    this.groups = const <String>[],
    this.groupLabels = const <String, String>{},
    this.channelAutoTags = const <String>{},
    this.selectedGroup,
    this.nodes = const <String>[],
    this.activeInGroup,
    this.highlightedNode,
    this.delayByChannel = const <String, Map<String, int>>{},
    this.pingBusy = const <String, String>{},
    this.sickRoots = const <String, List<DependentRef>>{},
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
    this.lastStartError = '',
    this.lastStartErrorAt,
  })  : configModel = configModel ?? ParsedConfig.parse(configRaw),
        runningModel = runningModel ??
            (runningConfigRaw != null
                ? ParsedConfig.parse(runningConfigRaw)
                : null);

  /// Сохранённый конфиг (файл `singbox_config.json`) — то, что редактируется
  /// и с чем стартует СЛЕДУЮЩИЙ запуск. §311 — при живом туннеле может
  /// опережать работающее ядро (пересборка до рестарта); правду о запущенном
  /// см. [runningConfigRaw]/[activeModel].
  final String configRaw;

  /// §311 — канонический снапшот конфига РАБОТАЮЩЕГО ядра
  /// (`CommandClient.getRunningConfig`, kernel SPEC 036). `null` = недоступен:
  /// туннель down, старое ядро без метода, attached-путь, гонка старта.
  /// Это re-marshal распарсенных options (порядок полей, omitempty, `[]→null`,
  /// post-override tun) — НЕ участвует ни в каких diff'ах с [configRaw],
  /// только чтение структуры узлов для resolve/показа.
  final String? runningConfigRaw;

  /// §091 — распарсенный конфиг (`Map<tag, ConfigNode>` + структурные
  /// запросы). Статик-слой: пересобирается в `copyWith` ТОЛЬКО при смене
  /// `configRaw`; пинги/active/urltest живут в отдельных динамик-map'ах.
  final ParsedConfig configModel;

  /// §311 — распарсенный [runningConfigRaw] (та же parse-once дисциплина §091).
  final ParsedConfig? runningModel;

  /// §311 — модель для вопросов «как устроен узел, который сейчас крутится»:
  /// список нод приходит из памяти ядра (`ccGroups`, §122), значит и resolve
  /// тега обязан идти по срезу ядра — иначе в окне «пересборка до рестарта»
  /// UI мешает срезы (ложный «Not found» на видимую ноду, корень §309/§311).
  /// Фоллбэк на [configModel] (туннель down / старое ядро) = поведение до §311.
  ParsedConfig get activeModel =>
      (tunnelUp ? runningModel : null) ?? configModel;

  /// §311 — сырой аналог [activeModel] для потребителей строки
  /// (`RouteConfig.finalTag` шторки, StatsScreen).
  String get activeConfigRaw =>
      (tunnelUp ? runningConfigRaw : null) ?? configRaw;

  final TunnelStatus tunnel;

  /// §279 Phase 4 — хранимая ошибка = [UiMsg] (лениво рендерится в build,
  /// смена локали мгновенно перерендеривает). `null` = ошибки нет.
  final UiMsg? lastError;

  /// §279 — типизированный разбор ТЕКУЩЕГО [lastError], когда тот пришёл из
  /// stop-события native (parsed при ingestion, см. `StopReason.fromEvent`).
  /// `null` — lastError пуст или записан другим сайтом (ping/start/reload
  /// пишут произвольные строки). Инвариант поддерживает [copyWith]: любое
  /// обновление lastError без явного stopReason сбрасывает поле в null.
  final StopReason? stopReason;
  final bool busy;

  /// §122 — снапшот дерева групп из libbox CommandClient (`CcChannel.groups`).
  /// Источник истины для групп/нод/active-выбора (заменил Clash `proxiesJson`).
  final List<CcGroup> ccGroups;
  final List<String> groups;

  /// §125 — tag→label каналов (из storage `channels[]`). Для отображения
  /// человекочитаемого имени канала в home-dropdown вместо tag ('vpn-1').
  final Map<String, String> groupLabels;

  /// §322 — auto-теги каналов (`vpn-N-auto`). Пин в верхнюю секцию положен
  /// только им: у узла автовыбора подписки/папки тип тоже `urltest`, но он
  /// обычная нода списка и своего места не покидает.
  final Set<String> channelAutoTags;

  /// Человекочитаемое имя группы: label канала из storage, иначе сам tag.
  String groupLabelOf(String tag) => groupLabels[tag] ?? tag;

  final String? selectedGroup;
  final List<String> nodes;
  final String? activeInGroup;
  final String? highlightedNode;
  /// §325 — замеры пинга **по каналам**: `канал → тег ноды → ms`.
  ///
  /// Раньше это была одна плоская карта на всё приложение, и mass-ping,
  /// перебирающий ноды только текущего канала, чистил её целиком — пинги всех
  /// прочих каналов пропадали (жалобы 4PDA #1289/#1290/#1376/#1381/#1382).
  /// Теперь каждый канал ведёт свои замеры и чужие не трогает.
  ///
  /// Разделение нужно не только ради изоляции сброса: ping-URL и таймаут
  /// резолвятся **per-group** (§040), поэтому «180мс» из канала с быстрым
  /// endpoint'ом и из канала с медленным — разные величины, и складывать их
  /// в один ключ некорректно.
  ///
  /// Ключ канала — `selectedGroup`; замеры вне контекста канала (папки,
  /// проба подписок) живут под [scratchChannel]. Прямо читать эту карту не
  /// надо — см. [delayOf] / [delayIsForeign], они дают фоллбэк-семантику.
  final Map<String, Map<String, int>> delayByChannel;
  final Map<String, String> pingBusy;

  /// §355 — «корни беды»: мёртвая нода → её транзитивные пострадавшие (DNS и
  /// ноды, зависящие через detour/каналы). Пересчитывается HomeController'ом
  /// на замерах пинга и смене выбора групп ([DependencyGraph.computeSick]);
  /// пустая map = тревог нет. UI: ⚠-метка на корне + sheet со списком.
  final Map<String, List<DependentRef>> sickRoots;

  /// §325 — псевдо-канал для замеров, сделанных вне выбранного канала
  /// (`selectedGroup == null`). Отдельный ключ, а не «сложить в текущий»:
  /// иначе такие замеры присвоил бы себе случайный канал.
  static const String scratchChannel = ' scratch';

  /// §325 — ключ канала, в который пишутся новые замеры.
  String get delayChannelKey => selectedGroup ?? scratchChannel;

  /// §325 — замеры текущего канала (без фоллбэка). Источник истины для
  /// «мерили ли ноду именно здесь».
  Map<String, int> get _ownDelays =>
      delayByChannel[delayChannelKey] ?? const <String, int>{};

  /// §325 — пинг ноды для показа: свой замер канала, иначе последний известный
  /// из любого другого (фоллбэк). `null` — ноду не мерили нигде.
  ///
  /// Фоллбэк намеренный: строгая изоляция чтения дала бы пустой список после
  /// каждого переключения канала и вернула бы ровно ту ручную работу, на
  /// которую жаловались (#1290). Чужой замер помечается в UI — [delayIsForeign].
  int? delayOf(String tag) {
    final own = _ownDelays[tag];
    if (own != null) return own;
    for (final entry in delayByChannel.entries) {
      if (entry.key == delayChannelKey) continue;
      final v = entry.value[tag];
      if (v != null) return v;
    }
    return null;
  }

  /// §325 — показанный [delayOf] пришёл из ДРУГОГО канала (в текущем ноду не
  /// мерили). UI рисует такой замер приглушённо и со значком-пометкой.
  bool delayIsForeign(String tag) =>
      !_ownDelays.containsKey(tag) && delayOf(tag) != null;
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

  /// §250 — диагностический дубль [lastError] для Debug API: причина
  /// последнего аварийного стопа/revoke. В отличие от [lastError] НЕ
  /// расходуется UI (`clearError` §166 и оптимистичные `lastError: null` в
  /// start/stop/reload его не трогают); очищается ТОЛЬКО успешным стартом
  /// (`tunnel → connected`). In-memory by design — пусто после рестарта
  /// процесса.
  final String lastStartError;

  /// §250 — когда [lastStartError] был записан (null, если пусто).
  final DateTime? lastStartErrorAt;

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
  /// §311 — activeModel: tag приходит из списка (= из ядра при tunnelUp).
  bool isControlTag(String tag) {
    final g = groupOf(tag);
    if (g != null && (_isSelector(g.type) || _isUrltest(g.type))) return true;
    return activeModel[tag]?.isControl ?? false;
  }

  /// §359 — control-узел, созданный ПРИЛОЖЕНИЕМ (шасси), а не пришедший
  /// контентом из подписки/папки. Фильтр списка короткозамыкает в matching
  /// только такие: узел автовыбора подписки (§322) — обычная нода списка и
  /// фильтруется наравне со всеми (regex, чипы, пинг, detour-pool).
  ///
  /// Шасси = селектор канала (`vpn-N`, ключи `groupLabels` из storage
  /// `channels[]`, §125) + его auto-двойник (`channelAutoTags`, §322).
  /// `direct`/`block`/`dns` — по ТИПУ, не по тегу: подписка не может прислать
  /// узел такого типа, а теги расходятся (`block` в `magic_nodes` шаблона vs
  /// `block-out` в аллокаторе `build_config`) — литерал был бы ловушкой.
  bool isSystemControlTag(String tag) {
    if (groupLabels.containsKey(tag) || channelAutoTags.contains(tag)) {
      return true;
    }
    final t = activeModel[tag]?.type;
    return t == 'direct' || t == 'block' || t == 'dns';
  }

  /// Все urltest-группы (для форс-URLTest после mass-ping, §070).
  Iterable<CcGroup> get urltestGroups =>
      ccGroups.where((g) => _isUrltest(g.type));

  /// Memoized sort — вычисляется один раз на жизнь этого `HomeState`
  /// инстанса. Новый `copyWith` создаёт новый state → новый late-кэш;
  /// если `nodes`/`sortMode`/`delayByChannel` не поменялись между emit'ами,
  /// HomeController всё равно создаст новый state — это отдельная
  /// оптимизация (batched emit). Здесь спасаем от повторного sort
  /// в пределах одного ребилд-цикла виджетов, который обращается к
  /// `sortedNodes` несколько раз (фильтр detour + итерация + builder).
  late final List<String> sortedNodes = _computeSortedNodes();

  /// §070/§125/§196 — pinned-секция (всегда сверху, non-draggable): direct →
  /// urltest-двойники → активная нода. Вычисляется один раз, используется
  /// `sortedNodes` и `pinnedNodeCount` (node_list — для drag-handle gating).
  late final List<String> _pinnedTags = _computePinned();

  /// Кол-во pinned-нод в начале [sortedNodes]. node_list: первые N
  /// non-draggable (§071). Источник истины — [_computePinned], не пересчёт по
  /// тегам (auto-двойники теперь vpn-N-auto, §125).
  int get pinnedNodeCount => _pinnedTags.length;

  /// §070/§125/§196/§201 — наполнение pinned section. pinDirect/pinAuto —
  /// тоглы (§070); block и активная нода пинятся ВСЕГДА (при любой сортировке).
  /// Пин по ТИПУ из конфига (`direct`/`urltest`/`block`), не по фикс-тегам.
  /// Порядок: direct → urltest-двойники → block → активная.
  List<String> _computePinned() {
    // §311 — activeModel: сортируем `nodes` (срез ядра при tunnelUp), значит
    // и тип узла берём из того же среза, иначе pin-by-type мажет по тегам.
    final model = activeModel;
    final pinnedSet = <String>{
      for (final n in nodes)
        if ((pinDirect && model[n]?.type == 'direct') ||
            // §322 — только auto-двойник КАНАЛА; группа автовыбора остаётся
            // на своём месте в списке.
            (pinAuto &&
                model[n]?.type == 'urltest' &&
                channelAutoTags.contains(n)) ||
            model[n]?.type == 'block') // §201 — block всегда сверху
          n,
    };
    final pinned = [
      ...nodes.where((n) => pinnedSet.contains(n) && model[n]?.type == 'direct'),
      ...nodes.where((n) =>
          pinnedSet.contains(n) &&
          model[n]?.type == 'urltest' &&
          channelAutoTags.contains(n)),
      ...nodes.where((n) => pinnedSet.contains(n) && model[n]?.type == 'block'),
    ];
    // §196 — активная нода группы сразу ПОСЛЕ direct/auto, при ЛЮБОЙ сортировке
    // (не за тоглом). Только реальная прокси-нода (не сам direct/auto-двойник,
    // иначе дубль) и присутствующая в списке.
    final active = activeInGroup;
    if (active != null &&
        active.isNotEmpty &&
        nodes.contains(active) &&
        !pinnedSet.contains(active)) {
      pinned.add(active);
    }
    return pinned;
  }

  List<String> _computeSortedNodes() {
    final pinned = _pinnedTags;
    final pinnedSet = pinned.toSet();
    final rest = nodes.where((n) => !pinnedSet.contains(n)).toList();
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
    // §325 — сортируем по тому же числу, что видит пользователь (вкл. фоллбэк
    // из чужого канала): иначе нода с показанным «120MS» уезжала бы в хвост
    // к неизмеренным.
    final da = delayOf(a);
    final db = delayOf(b);
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
    // §311 — _unset-паттерн: снапшот надо уметь СБРАСЫВАТЬ в null (down /
    // reload / новая сессия), обычный `??` этого не умеет.
    Object? runningConfigRaw = _unset,
    TunnelStatus? tunnel,
    Object? lastError = _unset,
    Object? stopReason = _unset,
    bool? busy,
    List<CcGroup>? ccGroups,
    List<String>? groups,
    Map<String, String>? groupLabels,
    Set<String>? channelAutoTags,
    Object? selectedGroup = _unset,
    List<String>? nodes,
    Object? activeInGroup = _unset,
    Object? highlightedNode = _unset,
    Map<String, Map<String, int>>? delayByChannel,
    Map<String, String>? pingBusy,
    Map<String, List<DependentRef>>? sickRoots,
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
    String? lastStartError,
    Object? lastStartErrorAt = _unset,
  }) {
    return HomeState(
      configRaw: configRaw ?? this.configRaw,
      runningConfigRaw: identical(runningConfigRaw, _unset)
          ? this.runningConfigRaw
          : runningConfigRaw as String?,
      // configModel пересчитываем ТОЛЬКО при смене configRaw. Иначе шарим
      // тот же immutable объект — несколько copyWith без configRaw не
      // делают jsonDecode.
      configModel:
          configRaw != null ? ParsedConfig.parse(configRaw) : configModel,
      // §311 — та же parse-once дисциплина для снапшота ядра: новый raw →
      // парс; явный null → сброс модели; _unset → шарим текущий объект.
      runningModel: identical(runningConfigRaw, _unset)
          ? runningModel
          : (runningConfigRaw is String
              ? ParsedConfig.parse(runningConfigRaw)
              : null),
      tunnel: tunnel ?? this.tunnel,
      lastError: identical(lastError, _unset)
          ? this.lastError
          : lastError as UiMsg?,
      // §279 — stopReason валиден только для lastError, вместе с которым был
      // распарсен: смена lastError без явного stopReason обнуляет его.
      stopReason: identical(stopReason, _unset)
          ? (identical(lastError, _unset) ? this.stopReason : null)
          : stopReason as StopReason?,
      busy: busy ?? this.busy,
      ccGroups: ccGroups ?? this.ccGroups,
      groups: groups ?? this.groups,
      groupLabels: groupLabels ?? this.groupLabels,
      channelAutoTags: channelAutoTags ?? this.channelAutoTags,
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
      delayByChannel: delayByChannel ?? this.delayByChannel,
      pingBusy: pingBusy ?? this.pingBusy,
      sickRoots: sickRoots ?? this.sickRoots,
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
      lastStartError: lastStartError ?? this.lastStartError,
      lastStartErrorAt: identical(lastStartErrorAt, _unset)
          ? this.lastStartErrorAt
          : lastStartErrorAt as DateTime?,
    );
  }
}

const _unset = Object();
