// §125 — Настраиваемые Направления роутинга.
//
// `Direction` заменяет статичный `PresetGroup` из `wizard_template.json` как
// source-of-truth: Направления переезжают из template в `lxbox_settings.json`
// (`directions[]`). Template остаётся seed'ом для первого запуска (см. миграцию
// в `settings_storage/directions.dart`).
//
// `tag` — СИСТЕМНЫЙ immutable id ('vpn-1'..'vpn-10'): автогенерируется при
// создании, юзер правит только `label`. immutable tag ⇒ ссылки (route_final /
// ping_options / custom-rule outbound / detour) стабильны by design.
//
// Спека: docs/spec/features/125 configurable-directions/spec.md.

import '../config/consts.dart' show kDetourTagPrefix;
import 'parser_config.dart' show DirectionTemplate, DefaultDirection;

/// Максимум Направлений (Решение 5). vpn-1 неудаляем, N∈1..10.
const int kMaxDirections = 10;

/// §198 — дефолтный label Направления по номеру: «VPN ①»…«VPN ⑩». Кружок-цифра —
/// Unicode «Enclosed Alphanumerics» (① = U+2460, идут подряд 1..10). N вне
/// 1..10 → без кружка («VPN N»).
String defaultDirectionLabel(int n) {
  if (n < 1 || n > 10) return 'VPN $n';
  return 'VPN ${String.fromCharCode(0x2460 + n - 1)}';
}

/// Номер Направления из tag 'vpn-N' (для дефолтного label). null если не парсится.
int? directionNumberOf(String tag) {
  final m = RegExp(r'^vpn-(\d+)$').firstMatch(tag);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// uint16 верхняя граница для `tolerance` (§161 — вне диапазона роняет ядро).
const int _kToleranceMax = 65535;

/// §161 — клэмп tolerance/pool_tolerance в uint16 [0, 65535]. §219/§221 —
/// публичная (direction_edit клэмпит в снапшоте, симметрично clampDirectionPool).
int clampDirectionTolerance(int v) => v < 0 ? 0 : (v > _kToleranceMax ? _kToleranceMax : v);

/// §208 — режим выбора узла в auto-группе (urltest, ядро SPEC 019 V2).
/// `leastTest` — апстрим: один лучший по delay (как было всегда).
/// `roundRobin` — балансировка по пулу (читает [Direction.auto] balancer-поля).
enum UrltestMode {
  leastTest('least_test'),
  roundRobin('round_robin');

  const UrltestMode(this.wire);

  /// Значение в config-JSON (`mode`).
  final String wire;

  static UrltestMode fromWire(String? s) =>
      UrltestMode.values.firstWhere((m) => m.wire == s,
          orElse: () => UrltestMode.leastTest);
}

/// §208 — компонент ключа sticky-сессии (round_robin, `balancer.sticky_hash`).
enum StickyHashKey {
  process('process'),
  domain('domain'),
  sourceIp('source_ip'),
  destIp('dest_ip'),
  destPort('dest_port');

  const StickyHashKey(this.wire);

  /// Значение в config-JSON (элемент `sticky_hash[]`).
  final String wire;

  static StickyHashKey? fromWire(String? s) {
    for (final k in StickyHashKey.values) {
      if (k.wire == s) return k;
    }
    return null;
  }
}

/// §208 — дефолтный sticky-набор для нового round_robin-пула (липкость по
/// процессу+домену — на практике сессии почти всегда нужны, как дефолт ядра).
const List<StickyHashKey> kDefaultStickyHash = [
  StickyHashKey.process,
  StickyHashKey.domain,
];

/// §208 — нижняя граница размера пула. Ядро `0`→дефолт 3, отриц.→ошибка; из UI
/// шлём всегда осмысленное (min 1), кламп на клиенте безопаснее. §219 —
/// публичная (переиспользуется direction_edit_screen для снапшота).
int clampDirectionPool(int v) => v < 1 ? 1 : v;

/// Параметры urltest-двойника Направления (`<tag>-auto`). null-аналог на уровне
/// [Direction.auto] == null означает «галка auto ВЫКЛ, двойник не эмитится».
/// `tag` двойника НЕ хранится — производный (`direction.autoTag`).
class DirectionAuto {
  const DirectionAuto({
    this.url = 'https://cp.cloudflare.com/generate_204',
    // §272 — 15m вместо 5m: на mobile каждый цикл проб дайлит узлы (будит
    // спящие, SPEC 020); с passive_check пробы при живом трафике и так
    // пропускаются, interval задаёт лишь скорость реакции на смерть узла.
    // Существующие Направления хранят своё значение в JSON — их это не меняет.
    this.interval = '15m',
    this.tolerance = 50,
    this.idleTimeout = '30m',
    this.interruptExistConnections = false,
    this.mode = UrltestMode.leastTest,
    this.pool = 3,
    this.poolTolerance = 0,
    this.stickyHash = kDefaultStickyHash,
  });

  final String url; // urltest test endpoint
  final String interval; // duration ("5m")
  final int tolerance; // ms, uint16 (§161)
  final String idleTimeout; // duration ("30m")
  final bool interruptExistConnections; // urltest.interrupt_exist_connections

  /// §208 — режим выбора узла (least_test ⇄ round_robin). Только round_robin
  /// эмитит `balancer{}` в config.
  final UrltestMode mode;

  /// §208 — `balancer.pool`: размер пула round_robin. clamp ≥1 (см. clampDirectionPool).
  final int pool;

  /// §208 — `balancer.pool_tolerance` (мс). 0 = держать пул живых; >0 = отбор
  /// лучших по delay. clamp как tolerance (uint16).
  final int poolTolerance;

  /// §208 — `balancer.sticky_hash[]`: компоненты ключа липкости. Пустой список
  /// → `sticky_hash: []` (липкость выключена, чистая ротация).
  final List<StickyHashKey> stickyHash;

  DirectionAuto copyWith({
    String? url,
    String? interval,
    int? tolerance,
    String? idleTimeout,
    bool? interruptExistConnections,
    UrltestMode? mode,
    int? pool,
    int? poolTolerance,
    List<StickyHashKey>? stickyHash,
  }) =>
      DirectionAuto(
        url: url ?? this.url,
        interval: interval ?? this.interval,
        tolerance: tolerance == null ? this.tolerance : clampDirectionTolerance(tolerance),
        idleTimeout: idleTimeout ?? this.idleTimeout,
        interruptExistConnections:
            interruptExistConnections ?? this.interruptExistConnections,
        mode: mode ?? this.mode,
        pool: pool == null ? this.pool : clampDirectionPool(pool),
        poolTolerance:
            poolTolerance == null ? this.poolTolerance : clampDirectionTolerance(poolTolerance),
        stickyHash: stickyHash ?? this.stickyHash,
      );

  factory DirectionAuto.fromJson(Map<String, dynamic> json) {
    // §208 — balancer-поля вложены в `balancer{}` (зеркало config-ядра). Старый
    // Направление без `balancer`/`mode` → leastTest + дефолты (обратная совместимость).
    final bal = json['balancer'];
    final balMap = bal is Map<String, dynamic> ? bal : const <String, dynamic>{};
    final rawSticky = balMap['sticky_hash'];
    final sticky = rawSticky is List
        ? rawSticky
            .map((e) => StickyHashKey.fromWire(e as String?))
            .whereType<StickyHashKey>()
            .toList()
        : kDefaultStickyHash;
    return DirectionAuto(
      url: json['url'] as String? ?? 'https://cp.cloudflare.com/generate_204',
      interval: json['interval'] as String? ?? '5m',
      tolerance: clampDirectionTolerance((json['tolerance'] as num?)?.toInt() ?? 50),
      idleTimeout: json['idle_timeout'] as String? ?? '30m',
      interruptExistConnections:
          json['interrupt_exist_connections'] as bool? ?? false,
      mode: UrltestMode.fromWire(json['mode'] as String?),
      pool: clampDirectionPool((balMap['pool'] as num?)?.toInt() ?? 3),
      poolTolerance:
          clampDirectionTolerance((balMap['pool_tolerance'] as num?)?.toInt() ?? 0),
      // rawSticky == null (нет balancer) → дефолт; явный [] остаётся пустым.
      stickyHash: rawSticky is List
          ? sticky // (включая пустой [] = выкл)
          : kDefaultStickyHash,
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'interval': interval,
        'tolerance': clampDirectionTolerance(tolerance),
        'idle_timeout': idleTimeout,
        'interrupt_exist_connections': interruptExistConnections,
        // §208 — mode всегда; balancer всегда (для round-trip storage). Билдер
        // решает, эмитить ли balancer в config-ЯДРА (только round_robin).
        'mode': mode.wire,
        'balancer': {
          'pool': clampDirectionPool(pool),
          'pool_tolerance': clampDirectionTolerance(poolTolerance),
          'sticky_hash': stickyHash.map((k) => k.wire).toList(),
        },
      };
}

/// Пользовательское Направление роутинга. Хранится в `directions[]`. На первом запуске
/// seeded из `template.groupTemplates` (`default_directions` + `direction`-шаблон;
/// см. миграцию, §267).
class Direction {
  const Direction({
    required this.tag,
    required this.label,
    this.enabled = true,
    this.includeDirect = false,
    this.includeBlock = false,
    this.nodeFilter = '',
    this.nodeFilterInvert = false,
    this.defaultFilter = '',
    this.interruptExistConnections = true,
    this.auto,
    this.isDetour = false,
  });

  /// 'vpn-1'..'vpn-10' — системный immutable id (автоген, юзер НЕ правит).
  final String tag;

  /// Отображаемое имя ("Моя Германия") — единственное, что юзер вводит как «имя».
  final String label;

  /// Вкл/выкл (заменяет enabled_groups[]). vpn-1 всегда true инвариантом.
  final bool enabled;

  /// Галка: добавить `direct-out` опцией в селектор Направления.
  final bool includeDirect;

  /// §201 — галка: добавить `block` (дроп трафика) опцией в селектор Направления.
  final bool includeBlock;

  /// regex по ИТОГОВОМУ tag ноды (§048-style, `n.tag.contains`/`RegExp.hasMatch`).
  /// '' → все ноды (текущее поведение).
  final String nodeFilter;

  /// §197 — инверсия node_filter (как `!`-тогл в §048). true → в Направление попадают
  /// ноды, чей tag НЕ матчит [nodeFilter] (исключающий фильтр). Пустой
  /// nodeFilter → инверсия игнорируется (все ноды).
  final bool nodeFilterInvert;

  /// regex; первая matched нода → `options.default`. '' → default не выставляется.
  final String defaultFilter;

  /// selector.interrupt_exist_connections (template = true).
  final bool interruptExistConnections;

  /// urltest-двойник. null → галка ВЫКЛ, `<tag>-auto` не эмитится.
  final DirectionAuto? auto;

  /// §248/§274 — РАЗРЕШЕНИЕ выбирать Направление как detour-мишень для
  /// серверов/папок/подписок (пикер §239). Роль в правилах ортогональна:
  /// Направление с флагом остаётся валидной целью route_final / custom-rule
  /// outbound (§274 снял взаимоисключение ролей §248). Маркер в UI —
  /// префикс ⚙ ([displayLabel]). Единственный инвариант («vpn-1 не
  /// detour») принуждается в [Direction.fromJson] — restore из backup пишет
  /// raw JSON мимо UI/storage/API, только read-time коэрс закрывает все пути.
  final bool isDetour;

  /// §274 — ⚙ живёт в САМОМ label (storage), как ⚙-метка в тегах
  /// detour-серверов §080/§090: [normalizeLabel] в [copyWith]/[fromJson]
  /// переименовывает Направление при смене флага (set → '⚙ <label>', unset →
  /// префикс срезается; ⚙ зарезервирован как маркер — руками его не снять,
  /// нормализация вернёт). Display-сайты берут имя отсюда: это label (или
  /// tag, если label пуст) + страховочный префикс для объектов, созданных
  /// прямым конструктором мимо нормализации. Дедуп гарантирован.
  String get displayLabel {
    final base = label.isNotEmpty ? label : tag;
    if (!isDetour || base.startsWith(kDetourTagPrefix)) return base;
    return '$kDetourTagPrefix$base';
  }

  /// §274 — единая точка «переименования» detour-Направления: label обязан
  /// начинаться с [kDetourTagPrefix] при [isDetour] и НЕ начинаться без
  /// него. Пустой label не трогаем (display-фолбэк на tag — в
  /// [displayLabel]). Зовётся из [copyWith] (редактор, Debug API, storage)
  /// и [fromJson] (restore из backup / ручная правка файла).
  static String normalizeLabel(String label, bool isDetour) {
    if (label.isEmpty) return label;
    final marked = label.startsWith(kDetourTagPrefix);
    if (isDetour && !marked) return '$kDetourTagPrefix$label';
    if (!isDetour && marked) return label.substring(kDetourTagPrefix.length);
    return label;
  }

  /// Производный tag urltest-двойника. В storage НЕ хранится.
  ///
  /// §267 — источник истины формулы = `magic_nodes.auto.tpl` в шаблоне
  /// (`'{parent_tag}-auto'`), эквивалентно `resolveTpl(tpl, tag)`. Значение
  /// здесь захардкожено (дефис!): менять нельзя — сломает матч auto-двойников
  /// (`vpn-1-auto`) в фильтрах/сортировке. Инвариант равенства покрыт тестом.
  String get autoTag => '$tag-auto';

  /// vpn-1 — продуктово-привилегированный: всегда enabled, неудаляемый,
  /// дефолт route_final. Намеренный хардкод (продуктовое решение).
  bool get isRequired => tag == 'vpn-1';

  Direction copyWith({
    String? label,
    bool? enabled,
    bool? includeDirect,
    bool? includeBlock,
    String? nodeFilter,
    bool? nodeFilterInvert,
    String? defaultFilter,
    bool? interruptExistConnections,
    DirectionAuto? auto,
    bool clearAuto = false,
    bool? isDetour,
  }) =>
      Direction(
        tag: tag, // immutable — не параметр copyWith
        // §274 — смена detour-флага переименовывает Направление (⚙ в label).
        label: normalizeLabel(label ?? this.label, isDetour ?? this.isDetour),
        enabled: enabled ?? this.enabled,
        includeDirect: includeDirect ?? this.includeDirect,
        includeBlock: includeBlock ?? this.includeBlock,
        nodeFilter: nodeFilter ?? this.nodeFilter,
        nodeFilterInvert: nodeFilterInvert ?? this.nodeFilterInvert,
        defaultFilter: defaultFilter ?? this.defaultFilter,
        interruptExistConnections:
            interruptExistConnections ?? this.interruptExistConnections,
        auto: clearAuto ? null : (auto ?? this.auto),
        isDetour: isDetour ?? this.isDetour,
      );

  factory Direction.fromJson(Map<String, dynamic> json) {
    final rawAuto = json['auto'];
    final tag = json['tag'] as String? ?? '';
    // §248/§274 — parse-гейт (единственная точка, которую не обходит restore
    // из backup / ручная правка файла): vpn-1 — главное Направление, дефолтная
    // мишень всего и heal-резерв, detour-флаг ему запрещён (продуктовое
    // решение). Коэрция include_block у detour-Направления снята §274 —
    // комбинация легальна.
    final isDetour = tag != 'vpn-1' && (json['detour'] as bool? ?? false);
    return Direction(
      tag: tag,
      // §274 — read-time нормализация ⚙-префикса (restore/ручная правка).
      label: normalizeLabel(json['label'] as String? ?? tag, isDetour),
      enabled: json['enabled'] as bool? ?? true,
      includeDirect: json['include_direct'] as bool? ?? false,
      includeBlock: json['include_block'] as bool? ?? false,
      nodeFilter: json['node_filter'] as String? ?? '',
      nodeFilterInvert: json['node_filter_invert'] as bool? ?? false,
      defaultFilter: json['default_filter'] as String? ?? '',
      interruptExistConnections:
          json['interrupt_exist_connections'] as bool? ?? true,
      auto: rawAuto is Map<String, dynamic>
          ? DirectionAuto.fromJson(rawAuto)
          : null,
      isDetour: isDetour,
    );
  }

  Map<String, dynamic> toJson() => {
        'tag': tag,
        'label': label,
        'enabled': enabled,
        'include_direct': includeDirect,
        'include_block': includeBlock,
        'node_filter': nodeFilter,
        'node_filter_invert': nodeFilterInvert,
        'default_filter': defaultFilter,
        'interrupt_exist_connections': interruptExistConnections,
        'auto': auto?.toJson(), // null остаётся null в JSON (галка ВЫКЛ)
        'detour': isDetour, // §248
      };

  /// §267 — seed-Направление из `default_directions[i]` + общего шаблона `direction`
  /// (миграция first-run). `auto` берётся снаружи (нужен доступ к urltest-vars),
  /// здесь — только структурные поля. `include` содержит role-ключи
  /// `magic_nodes` (`direct`/`auto`/`block`) — это роли, НЕ теги. См.
  /// `_migrateDirectionsIfNeeded`.
  static Direction seedFromDefault(
    DefaultDirection dc,
    DirectionTemplate tpl, {
    required bool enabled,
    DirectionAuto? auto,
  }) =>
      Direction(
        tag: dc.tag,
        label: dc.label.isEmpty ? dc.tag : dc.label,
        enabled: enabled,
        includeDirect: tpl.include.contains('direct'),
        includeBlock: tpl.include.contains('block'), // §201 (в дефолте нет → false)
        nodeFilter: '',
        defaultFilter: '', // Решение 6 — старый default не regex, не мигрируем
        interruptExistConnections:
            tpl.options['interrupt_exist_connections'] as bool? ?? true,
        auto: auto,
      );
}
