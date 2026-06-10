import '../../controllers/home_controller.dart';
import '../../controllers/subscription_controller.dart';
import '../../models/home_state.dart';
import '../../models/server_list.dart';
import '../../services/clash_api_client.dart';
import 'node_filter.dart';
import 'node_filter_view_model.dart';
import 'subscription_lookup.dart';

/// Короткий label протокола для строки ноды. TLS опускаем — у большинства
/// протоколов (VLESS/Trojan/Hy2/TUIC) он дефолт, метить каждую — шум.
String protoLabel(String type) => switch (type) {
      'vless' => 'VLESS',
      'vmess' => 'VMess',
      'trojan' => 'Trojan',
      'shadowsocks' => 'SS',
      'hysteria2' => 'Hy2',
      'tuic' => 'TUIC',
      'wireguard' => 'WG',
      'ssh' => 'SSH',
      'socks' => 'SOCKS',
      'http' => 'HTTP',
      _ => type.toUpperCase(),
    };

/// Prep-logic для node-list главного экрана.
///
/// Владеет:
/// - §070 frozen-sort UI-cache ([_cachedSorted]/[_cachedSortKey]) — должен
///   жить через rebuild'ы (создаётся один раз в `initState`, hold как
///   `late final`), семантика cache-key + invalidation идентична оригиналу;
/// - §085 R3 сборка `NodeFilter` из `NodeFilterViewModel` + state-зависимых
///   lookup'ов (`protocolOf`/`subscriptionsOf`/`isControlTag`);
/// - §048 split pool → matching/non-matching (control-узлы §078 короткозамкнуты);
/// - §078 displayList computation для ping-button order.
///
/// Читает `controller.state` / `subController.entries` свежими на каждый вызов
/// (как и раньше в `_HomeScreenState`), поэтому stateless относительно
/// контроллеров — единственное mutable-состояние = sort cache.
class NodeListPresenter {
  NodeListPresenter({
    required this.controller,
    required this.subController,
    required this.filter,
  });

  final HomeController controller;
  final SubscriptionController subController;
  final NodeFilterViewModel filter;

  // §070 — UI-cache для frozen sort при `state.resortOnManualPing == false`.
  // См. spec'у — manual single ping не двигает порядок, batch / group switch /
  // config rebuild сбрасывает через `state.pingBatchGen` bump.
  List<String>? _cachedSorted;
  ({NodeSortMode mode, int gen, int nodesLen, bool pinD, bool pinA})?
      _cachedSortKey;

  /// Lookup protocol for tag — учитывает urltest group fallback (см. §048
  /// «Protocol detection»). Возвращает null если cache miss и urltest нет.
  String? protocolOfTag(String tag, HomeState state) {
    final model = state.configModel;
    final urltestNow = ClashApiClient.urltestNow(state.proxiesJson, tag);
    return model.protocolOf(tag) ??
        (urltestNow != null ? model.protocolOf(urltestNow) : null);
  }

  /// §103 — transport/security теги ноды для variant-фильтра. Тот же
  /// urltest-fallback что у [protocolOfTag] (payload-узел, давший протокол,
  /// даёт и теги). Пустой Set = unknown.
  Set<String> variantsOfTag(String tag, HomeState state) {
    final model = state.configModel;
    var n = model[tag];
    if (n == null || n.isControl || n.type.isEmpty) {
      final urltestNow = ClashApiClient.urltestNow(state.proxiesJson, tag);
      n = urltestNow != null ? model[urltestNow] : null;
      // Паритет с protocolOfTag: fallback-цель тоже должна быть payload-узлом
      // (control с tls/transport-полями дал бы лейблы при protocol == null).
      if (n != null && (n.isControl || n.type.isEmpty)) n = null;
    }
    if (n == null) return const <String>{};
    return {
      ?n.transportLabel,
      ?n.securityLabel,
    };
  }

  /// §103 — канонический порядок variant-чипов: транспорты, затем security;
  /// незнакомые теги — в конец по алфавиту (forward-compat).
  static const _variantOrder = <String>[
    'tcp', 'ws', 'grpc', 'h2', 'httpupgrade', 'quic', 'xhttp',
    'TLS', 'TLS+Vision', 'Reality', 'Reality+Vision', 'awg', 'awg2',
  ];

  static int _variantRank(String v) {
    final i = _variantOrder.indexOf(v);
    return i >= 0 ? i : _variantOrder.length;
  }

  /// §091 — какие подписки владеют тегом (prefix-based). Тонкая обёртка
  /// над pure helper'ом `subscriptionsOfTag` (см. `home/subscription_lookup.dart`).
  Set<String> subscriptionsOfTag_(String tag) =>
      subscriptionsOfTag(tag, subController.entries);

  /// §078 — True если outbound с этим tag'ом — control (selector / urltest
  /// / direct / block / dns), не payload-нода. Source-of-truth =
  /// `state.proxiesJson` (Clash API знает типы outbound'ов лучше нас).
  ///
  /// Caller использует чтобы (a) короткозамкнуть filter passing — control
  /// ноды **всегда** matching независимо от фильтров, (b) исключить из
  /// 'Custom' chip detection — empty `subscriptionsOf` у control'ов не
  /// должен триггерить 'Custom' chip когда у юзера нет UserServer'ов.
  static const _controlProxyTypes = <String>{
    'selector', 'urltest', 'direct', 'block', 'dns',
  };

  bool isControlTag(String tag, HomeState state) {
    final pmap = state.proxiesJson['proxies'];
    if (pmap is! Map<String, dynamic>) return false;
    final entry = pmap[tag];
    if (entry is! Map<String, dynamic>) return false;
    final type = (entry['type'] as String?)?.toLowerCase() ?? '';
    return _controlProxyTypes.contains(type);
  }

  /// §085 R3 — единый `NodeFilter` из view-model + state-зависимых lookup'ов.
  /// Используется и `computeDisplayList`, и node-list (был дубль §078).
  NodeFilter buildNodeFilter(HomeState state) => NodeFilter(
        regex: filter.activeRegex,
        regexInvert: filter.regexInvert,
        protocols: filter.enabledProtocols,
        protocolsInvert: filter.protocolsInvert,
        variants: filter.enabledVariants,
        variantsInvert: filter.variantsInvert,
        subscriptions: filter.enabledSubscriptions,
        subscriptionsInvert: filter.subscriptionsInvert,
        maxPingMs: filter.activeMaxPingMs,
        protocolOf: (t) => protocolOfTag(t, state),
        variantsOf: (t) => variantsOfTag(t, state),
        subscriptionsOf: subscriptionsOfTag_,
        pingOf: (t) => state.lastDelay[t],
      );

  /// §085 R3 — pool (detour-фильтр) → split на matching/non-matching.
  /// §090 G2 — detour определяется по `ConfigNode.isDetour` (структурно: на ноду
  /// ссылаются как на hop), не по ⚙-метке. §096 — detour бинарный: скрыть
  /// detour (дефолт) / только detour ([detourPoolPasses]). Control-узлы
  /// (selector/urltest/direct/…) НИКОГДА не отсеиваются pool'ом (§078 — всегда
  /// видны, даже если случайно isDetour) и короткозамкнуты в matching.
  /// Возвращает `(matching, nonMatching)`.
  (List<String>, List<String>) splitNodes(
      List<String> sortedNodes, HomeState state) {
    final pool = sortedNodes
        .where((t) =>
            isControlTag(t, state) ||
            filter.detourPoolPasses(state.configModel[t]?.isDetour ?? false))
        .toList();
    final f = buildNodeFilter(state);
    final matching = <String>[];
    final nonMatching = <String>[];
    for (final tag in pool) {
      if (isControlTag(tag, state) || f.passes(tag)) {
        matching.add(tag);
      } else {
        nonMatching.add(tag);
      }
    }
    return (matching, nonMatching);
  }

  /// §078 — текущий displayList снаружи node-list (для ping button →
  /// `runMassUrltest(order:)` в порядке отображения).
  List<String> computeDisplayList(HomeState state) {
    final (matching, nonMatching) = splitNodes(viewSortedNodes(state), state);
    return filter.showNonMatching
        ? [...matching, ...nonMatching]
        : matching;
  }

  /// §070 — frozen sort при `resortOnManualPing == false`. Cache hit ↔
  /// (sortMode, pingBatchGen, nodes.length, pinDirect, pinAuto) совпадают
  /// с предыдущим вызовом + все cached tags ещё в pool. Manual single ping
  /// → новый state, та же key → cache hit → строка не прыгает.
  List<String> viewSortedNodes(HomeState s) {
    if (s.resortOnManualPing) {
      _cachedSortKey = null;
      _cachedSorted = null;
      return s.sortedNodes;
    }
    final key = (
      mode: s.sortMode,
      gen: s.pingBatchGen,
      nodesLen: s.nodes.length,
      pinD: s.pinDirect,
      pinA: s.pinAuto,
    );
    if (key == _cachedSortKey && _cachedSorted != null) {
      // sanity: все cached tags ещё в pool (защита от ноды удалённой из
      // подписки между bump'ами).
      if (_cachedSorted!.every(s.nodes.contains)) return _cachedSorted!;
    }
    _cachedSortKey = key;
    _cachedSorted = List<String>.unmodifiable(s.sortedNodes);
    return _cachedSorted!;
  }

  /// Aggregated данные для render node-list.
  /// Собирает sorted/pool/split/displayList + chip-options одним проходом.
  NodeListData computeListData(HomeState state) {
    // §048 — двухфазная модель (см. spec):
    // Phase 1 — pool filter: detour (§096 бинарный). §090 G2 — «detour»
    // СТРУКТУРНО: на ноду ссылаются как на detour-таргет (`ConfigNode.isDetour`,
    // detourRefCount>0), а не по ⚙-метке. §096 — скрыть detour (дефолт) /
    // только detour (см. [NodeFilterViewModel.detourPoolPasses]); control-узлы
    // никогда не отсеиваются. Pool здесь только для chip-опций
    // (availableProtocols); splitNodes re-derive'ит идентичный pool из allTags.
    // §070: используем viewSortedNodes — frozen sort при resortOnManualPing=false
    // (manual single ping не дёргает порядок).
    final allTags = viewSortedNodes(state);
    final pool = allTags
        .where((t) =>
            isControlTag(t, state) ||
            filter.detourPoolPasses(state.configModel[t]?.isDetour ?? false))
        .toList();

    // configModel парсится один раз при смене configRaw (см. HomeState),
    // здесь просто читаем. Раньше jsonDecode шёл на каждый rebuild
    // ListView — с 50+ нодами и сортировкой это был hot-path выжиматель.
    final cache = state.configModel;

    // §048 Phase 2 — match filter: split pool на matching + nonMatching
    // (control-узлы короткозамкнуты в matching, §078). См. `splitNodes`.
    final (matching, nonMatching) = splitNodes(allTags, state);
    final matchingSet = matching.toSet();

    // Render list = matching + (showNonMatching ? nonMatching : []).
    final displayList = filter.showNonMatching
        ? <String>[...matching, ...nonMatching]
        : matching;

    // Available для chips — из всего pool (не от current filter state).
    // Emoji — из allTags (locked decision #3, включая detour).
    final emojis = NodeFilter.extractEmojis(allTags);
    final availableProtocols = <String>{};
    final availableVariants = <String>{};
    for (final t in pool) {
      final p = protocolOfTag(t, state);
      if (p != null) availableProtocols.add(p);
      availableVariants.addAll(variantsOfTag(t, state));
    }
    final subOptions = <(String, String)>[];
    for (final e in subController.entries) {
      final list = e.list;
      // §091 — chip показываем только для enabled-подписки с непустым
      // префиксом И ≥1 нодой. Фильтрация теперь чисто prefix-based
      // (subscriptionsOfTag), поэтому без префикса chip бесполезен — её
      // ноды попадают в «Custom». Disabled / пустые → шум.
      if (list is SubscriptionServers &&
          e.enabled &&
          list.tagPrefix.isNotEmpty &&
          list.nodes.isNotEmpty) {
        subOptions.add((e.id, e.displayName));
      }
    }
    // §095 — синтетический «Custom»-чип убран (юзер): не-подписочные ноды
    // (UserServer / без префикса / импорт) фильтруются прочими средствами,
    // отдельный chip только путал.

    return NodeListData(
      cache: cache,
      matchingSet: matchingSet,
      displayList: displayList,
      emojis: emojis,
      availableProtocols: availableProtocols.toList()..sort(),
      availableVariants: availableVariants.toList()
        ..sort((a, b) {
          final byRank = _variantRank(a).compareTo(_variantRank(b));
          return byRank != 0 ? byRank : a.compareTo(b);
        }),
      subOptions: subOptions,
    );
  }
}

/// §089 — immutable bundle вычисленных данных для node-list render.
class NodeListData {
  const NodeListData({
    required this.cache,
    required this.matchingSet,
    required this.displayList,
    required this.emojis,
    required this.availableProtocols,
    required this.availableVariants,
    required this.subOptions,
  });

  final ParsedConfig cache;
  final Set<String> matchingSet;
  final List<String> displayList;
  final List<String> emojis;
  final List<String> availableProtocols;

  /// §103 — transport/security теги, присутствующие в pool'е (канонический
  /// порядок: транспорты → security).
  final List<String> availableVariants;

  final List<(String, String)> subOptions;
}
