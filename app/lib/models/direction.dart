// §125 — Настраиваемые Направления роутинга.
//
// `Direction` заменяет статичный `PresetGroup` из `wizard_template.json` как
// source-of-truth: Направления переезжают из template в `lxbox_settings.json`
// (`directions[]`). Template остаётся seed'ом для первого запуска (см. миграцию
// в `settings_storage/directions.dart`).
//
// `tag` — СИСТЕМНЫЙ immutable id: автовыдаётся как `vpn-N` (§393 A3 —
// `nextDirectionTag`, без верхней границы) либо задаётся пользователем при
// создании; после создания не меняется. immutable tag ⇒ ссылки (route_final /
// ping_options / custom-rule outbound / detour) стабильны by design.
//
// Спека: docs/spec/features/125 configurable-directions/spec.md.

import '../config/consts.dart'
    show kDetourTagPrefix, kDirectOutboundTag, kBlockOutboundTag;
import 'parser_config.dart' show DirectionTemplate, DefaultDirection;

/// Историческая граница на СОЗДАНИЕ Направлений; лимитом больше НЕ является
/// (§393 A3, паритет с лаунчером: `configtypes.NextDirectionTag` потолка не
/// имеет). Осталась константой-ориентиром для тестов.
const int kMaxDirections = 10;

/// §393 A3 — префикс автоматически выдаваемых тегов. Общий с лаунчером
/// (`configtypes.DirectionTagPrefix`): бэкап с десктопа обязан попадать в
/// существующее Направление, а не заводить рядом второе.
const String kDirectionTagPrefix = 'vpn-';

/// §393 A3 — первый свободный `vpn-N` среди [usedTags]. Порт
/// `configtypes.NextDirectionTag`.
///
/// Ищет первую свободную позицию, а не «максимум + 1»: после удаления
/// среднего Направления номера не должны уползать вверх — иначе `vpn-2`
/// навсегда исчезает из списка, хотя тег свободен, а пользователь видит
/// растущие числа при трёх живых Направлениях.
///
/// Потолка нет: [kMaxDirections] — не лимит модели.
String nextDirectionTag(Iterable<String> usedTags) {
  final used = usedTags.toSet();
  for (var i = 1;; i++) {
    final tag = '$kDirectionTagPrefix$i';
    if (!used.contains(tag)) return tag;
  }
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

/// §393 A3 — нормализация `include` на чтении: только непустые строки после
/// trim, без дублей, в порядке файла. Не-список / мусор → пустой список.
List<String> _parseInclude(Object? raw) {
  if (raw is! List) return const [];
  final out = <String>[];
  for (final e in raw) {
    if (e is! String) continue;
    final t = e.trim();
    if (t.isEmpty || out.contains(t)) continue;
    out.add(t);
  }
  return List.unmodifiable(out);
}

/// §393 A3 — вычеркнуть [deletedTag] из `include` каждого Направления списка.
/// Чистая функция: возвращает новый список и число вычеркнутых ссылок.
///
/// Третий род ссылки на Направление (после rules и detours, §202-паттерн) и
/// единственный, живущий не в чужом storage-ключе, а в САМОМ списке
/// Направлений. Из-за этого он нуждается в двух вызовах одной и той же
/// функции: storage лечит свою копию в `_deleteDirection`, экран роутинга —
/// свой буфер `_directions`, который он после мутации перезаписывает на диск
/// через `DirectionMutations.bulkReplace` (иначе stale-буфер воскресил бы
/// вычеркнутый тег). Отсюда — общая чистая функция вместо двух реализаций.
///
/// Зовётся ТОЛЬКО на удалении. Выключение обратимо: цель остаётся в списке,
/// форма рисует её снятым чекбоксом, билдер деградирует лишь выхлоп с
/// warning'ом — а вычистка `include` применила бы к обратимому действию
/// необратимость Решения B (§202).
///
/// Auto-двойник `<tag>-auto` вычищается заодно: в `include` он невалиден и так
/// (билдер сверяет теги с эмитированными СЕЛЕКТОРАМИ), но Debug API и
/// правленый бэкап записать его туда могут — та же причина, по которой его
/// проверяет `_healDirectionRefs`.
({List<Direction> healed, int count}) clearIncludeDirectionRefs(
  List<Direction> directions,
  String deletedTag,
) {
  final autoTag = '$deletedTag-auto';
  var count = 0;
  final out = <Direction>[];
  for (final c in directions) {
    final kept = c.include
        .where((t) => t != deletedTag && t != autoTag)
        .toList(growable: false);
    if (kept.length == c.include.length) {
      out.add(c);
      continue;
    }
    count += c.include.length - kept.length;
    out.add(c.copyWith(include: kept));
  }
  return (healed: out, count: count);
}

/// §393 A3 — теги, которые не может занять Направление: служебные outbound'ы
/// принимающего конфига и псевдо-цели правил sing-box.
///
/// `direct-out`/`block` — эмитятся шаблоном (`magic_nodes`) и предлагаются
/// опциями селектора (`include_direct`/`include_block`); Направление с таким
/// тегом дало бы дубль тега в `outbounds[]` — ядро отвергает конфиг целиком.
/// `block-out`/`dns-out` — заняты аллокатором тегов билдера
/// (`_BuildCtx._taken`). `reject`/`drop`/`direct` — ACTION-псевдоцели правил
/// (`custom_rule.dart:kOutboundReject`, `lx_backup._reservedOutbounds`):
/// Направление с таким именем сделало бы цель правила двусмысленной.
///
/// Тегов `<tag>-auto` тут нет намеренно: они зависят от текущего состава и
/// проверяются отдельно (см. [directionTagConflict]).
const Set<String> kReservedDirectionTags = {
  kDirectOutboundTag,
  kBlockOutboundTag,
  'block-out',
  'dns-out',
  'direct',
  'reject',
  'drop',
};

/// §393 A3 — суффикс парного urltest-двойника. Источник формулы — тот же,
/// что у [Direction.autoTag] (`magic_nodes.auto.tpl` = `{parent_tag}-auto`).
const String kDirectionAutoSuffix = '-auto';

/// §393 A3 — почему [tag] нельзя выдать новому Направлению; null = можно.
///
/// Возвращает МАШИННЫЙ код причины (call-site рисует текст): `empty`,
/// `reserved`, `duplicate`, `auto_twin` (тег занят двойником существующего
/// Направления либо сам порождает двойник, тезкой уже существующего тега).
///
/// [existingTags] — теги уже существующих Направлений.
String? directionTagConflict(String tag, Iterable<String> existingTags) {
  final t = tag.trim();
  if (t.isEmpty) return 'empty';
  if (kReservedDirectionTags.contains(t)) return 'reserved';
  final existing = existingTags.toSet();
  if (existing.contains(t)) return 'duplicate';
  // Новый тег не должен совпасть с двойником существующего Направления
  // (`vpn-1-auto` при живом `vpn-1`) …
  if (t.endsWith(kDirectionAutoSuffix) &&
      existing.contains(
          t.substring(0, t.length - kDirectionAutoSuffix.length))) {
    return 'auto_twin';
  }
  // … и его собственный двойник не должен затереть существующий тег
  // (`vpn-1` при живом `vpn-1-auto`).
  if (existing.contains('$t$kDirectionAutoSuffix')) return 'auto_twin';
  return null;
}

/// Пользовательское Направление роутинга. Хранится в `directions[]`. На первом запуске
/// seeded из `template.groupTemplates` (`default_directions` + `direction`-шаблон;
/// см. миграцию, §267).
class Direction {
  const Direction({
    required this.tag,
    this.enabled = true,
    this.includeDirect = false,
    this.includeBlock = false,
    this.include = const [],
    this.nodeFilter = '',
    this.nodeFilterInvert = false,
    this.defaultFilter = '',
    this.interruptExistConnections = true,
    this.auto,
    this.isDetour = false,
  });

  /// Системный immutable id: автовыданный `vpn-N` либо произвольный тег,
  /// заданный при СОЗДАНИИ (§393 A3). После создания не правится.
  final String tag;

  /// Вкл/выкл (заменяет enabled_groups[]). vpn-1 всегда true инвариантом.
  final bool enabled;

  /// Галка: добавить `direct-out` опцией в селектор Направления.
  final bool includeDirect;

  /// §201 — галка: добавить `block` (дроп трафика) опцией в селектор Направления.
  final bool includeBlock;

  /// §393 A3 — теги ДРУГИХ Направлений, предлагаемых опциями внутри этого
  /// (канон `direction.schema.json:include`, лаунчер —
  /// `Direction.AddOutbounds`). НЕ пересекается с [includeDirect]/
  /// [includeBlock]: те две — служебные опции `direct-out`/`block`, живут
  /// отдельными флагами и в `include` не попадают.
  ///
  /// АНТИЦИКЛ. Разрешены только Направления, стоящие ВЫШЕ по списку: порядок
  /// исключает циклы по построению. Инвариант принуждается в ДВУХ местах,
  /// как у лаунчера:
  ///   • форма не предлагает кандидатов ниже текущего (`tagsAbove` лаунчера,
  ///     `direction_edit_screen`);
  ///   • билдер эмитит в состав только те include-теги, что уже эмитированы
  ///     ВЫШЕ (`_buildDirectionGroups`); ссылка вниз / на несуществующее /
  ///     на выключенное Направление молча не эмитится, но даёт warning.
  ///
  /// Хранение ссылку НЕ санитайзит (лаунчер тоже: reorder только меняет
  /// порядок): пользователь вправе подвинуть Направление обратно и вернуть
  /// смысл ссылке. Деградирует ВЫХЛОП, не данные.
  ///
  /// Парный `<tag>-auto` сюда не попадает — двойник является опцией только
  /// своего Направления (канон схемы + `direction_twins.go`).
  final List<String> include;

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

  /// Имя для показа = сам [tag] плюс ⚙-маркер detour-мишени.
  ///
  /// Контракт 0.9.0 — второго имени у Направления нет: тег и есть имя.
  /// ⚙ раньше жил В САМОМ label в storage (§274) и нормализовался при смене
  /// флага; теперь префикс ЧИСТО производный — вычисляется здесь по
  /// [isDetour] и в данные не попадает. Дописывать его в tag нельзя: на тег
  /// ссылаются правила, `include`, хопы цепочек и detour-мишени, и маркер
  /// увёл бы тег из-под ссылок.
  String get displayLabel =>
      isDetour ? '$kDetourTagPrefix$tag' : tag;

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
    bool? enabled,
    bool? includeDirect,
    bool? includeBlock,
    List<String>? include,
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
        enabled: enabled ?? this.enabled,
        includeDirect: includeDirect ?? this.includeDirect,
        includeBlock: includeBlock ?? this.includeBlock,
        include: include ?? this.include,
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
      // Контракт 0.9.0 — ключ `label` старого состояния ЧИТАЕТСЯ И
      // ОТБРАСЫВАЕТСЯ: именем остаётся tag. Отдельной миграции файла не
      // нужно — ключ отмирает на первой же записи (toJson его не пишет).
      enabled: json['enabled'] as bool? ?? true,
      includeDirect: json['include_direct'] as bool? ?? false,
      includeBlock: json['include_block'] as bool? ?? false,
      // §393 A3 — отсутствие ключа = пустой список (байт-совместимость §221:
      // существующие storage/бэкапы ключа не имеют). Мусор (не-строки,
      // пустые после trim, дубли) отсеиваем на чтении — билдер не должен
      // разгребать вход руками правленного файла / restore из backup.
      include: _parseInclude(json['include']),
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
        // Контракт 0.9.0 — `label` не эмитится: имя у Направления одно, tag.
        'enabled': enabled,
        'include_direct': includeDirect,
        'include_block': includeBlock,
        // §393 A3 — пустой список ключа НЕ пишет: байт-совместимость §221 с
        // существующими storage-файлами и бэкапами (у них ключа нет вовсе,
        // и появление `"include": []` меняло бы diff всем сразу).
        if (include.isNotEmpty) 'include': include,
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
