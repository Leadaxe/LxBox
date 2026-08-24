import '../config/consts.dart' show kDirectOutboundTag;
import '../services/parser/uri_utils.dart' show newUuidV4;
import '../services/l10n/locale_controller.dart';

/// Sealed-иерархия пользовательских правил маршрутизации (spec §030, v1.4.1
/// task 011). Три варианта с разным шейпом и поведением:
///
/// - [CustomRuleInline] — юзер вручную описал match-поля (domain / suffix /
///   keyword / ip_cidr / port / package / protocol / private-ip). Данные
///   копией живут в самом правиле; билдер собирает headless rule_set.
/// - [CustomRuleSrs] — локально закэшированный `.srs`-бинарь по URL. Юзер
///   качает через ☁ (spec §011), sing-box получает `type: local, path`.
///   Доп-фильтры (port/packages/protocol/ipIsPrivate) применяются на
///   routing-rule уровне.
/// - [CustomRulePreset] — тонкая ссылка на `SelectableRule` в шаблоне.
///   Bundle-пресет с типизированными vars. Содержимое (rule_set / DNS /
///   routing) разворачивается на каждом `buildConfig`'е — обновил шаблон,
///   новое поведение у всех юзеров (spec §033).
///
/// `kind` — дискриминатор для JSON-сериализации (читается `fromJson`-ом
/// и выбирает правильный подкласс). В рантайме предпочтительнее
/// pattern-match `switch(cr)` — даёт exhaustive-проверку от компилятора.

/// §366 — TTL кэша rule-set'а по умолчанию: неделя. Списки блокировок и
/// geosite меняются медленно, чаще раза в неделю ходить в сеть незачем.
const int kDefaultSrsTtlHours = 168;

/// §366 — вшитый список вариантов TTL для выпадающего списка в редакторе
/// правила (часы). `0` = никогда не обновлять автоматически. Свободного
/// ввода нет: набор фиксирован, опечатки в «168h» никому не нужны.
const List<int> kSrsTtlChoicesHours = [
  0, // Never
  24, // 1 day
  168, // 1 week (default)
  336, // 2 weeks
  720, // 1 month
  4320, // 6 months
  8760, // 1 year
];

sealed class CustomRule {
  CustomRule({
    String? id,
    required this.name,
    required this.enabled,
    this.orderNum,
  }) : id = id ?? newUuidV4();

  final String id;
  String name;
  bool enabled;

  /// §370 — позиция на разреженной оси порядка правил (см. `parser_config.dart`
  /// `kUserRuleNumStart`). В JSON — ключ `num`; в Dart поле названо `orderNum`,
  /// потому что `num` — встроенный тип и линтер ругается на такое имя.
  ///
  /// `null` = правило ещё не размечено: так приезжает storage, записанный до
  /// §370. Разметка (`markRuleOrder`) проставляет номер при первой загрузке —
  /// отдельного версионированного шага миграции нет.
  int? orderNum;

  /// §393 B11 — поля записи LX Backup, которых мобила не понимает
  /// (`skip`/`detour` лаунчера и любые будущие ключи схемы).
  ///
  /// На поведение не влияют ВООБЩЕ: это транзитный груз, чтобы круг
  /// launcher→LxBox→launcher вернул правило целым, а не обеднённым
  /// (§1 BACKUP.md; эталон — `_backup_fields` в `core/backup/import.go`).
  /// Поле мутабельное и вне конструктора намеренно: конструкторы правил —
  /// пользовательский ввод, а этот груз кладёт ровно один импортёр.
  Map<String, dynamic> backupFields = const {};

  /// Ключ хранения [backupFields] в JSON правила. Служебный: подчёркивание
  /// отделяет его от полей модели и совпадает с именем на стороне лаунчера.
  static const String backupFieldsKey = '_backup_fields';

  /// Общий хвост `toJson` подклассов: служебный груз пишется только когда он
  /// есть — у подавляющего большинства правил его нет.
  Map<String, dynamic> get backupFieldsJson =>
      backupFields.isEmpty ? const {} : {backupFieldsKey: backupFields};

  /// Обратная операция для `fromJson` подклассов.
  static Map<String, dynamic> backupFieldsFromJson(Map<String, dynamic> j) {
    final raw = j[backupFieldsKey];
    return raw is Map ? raw.cast<String, dynamic>() : const {};
  }

  /// Переносит служебный груз на новый экземпляр (copyWith/импорт). Возвращает
  /// [to] — удобно в выражениях.
  static T carryBackupFields<T extends CustomRule>(T to, CustomRule from) {
    if (from.backupFields.isNotEmpty) to.backupFields = from.backupFields;
    return to;
  }

  /// Enum-дискриминатор для JSON. Значения совпадают с именами подклассов
  /// по convention (inline/srs/preset).
  CustomRuleKind get kind;

  Map<String, dynamic> toJson();

  /// Короткая сводка для subtitle на RoutingScreen. Пустая → UI покажет
  /// заглушку "Tap to edit". Существительные-счётчики через getLocalText.plural
  /// (рендер по локали в момент показа).
  String summary();

  // ─── Convenience getters — упрощают чтение в UI/builder без pattern-match.
  // Поля, которых нет в данном subclass, возвращают пустое/дефолтное
  // значение. Для записи используются type-specific `copyWith` и/или
  // `withEnabled` / `withName` / `withOutbound` ниже.

  List<String> get domains => switch (this) {
        CustomRuleInline(:final domains) => domains,
        _ => const [],
      };
  List<String> get domainSuffixes => switch (this) {
        CustomRuleInline(:final domainSuffixes) => domainSuffixes,
        _ => const [],
      };
  List<String> get domainKeywords => switch (this) {
        CustomRuleInline(:final domainKeywords) => domainKeywords,
        _ => const [],
      };
  List<String> get ipCidrs => switch (this) {
        CustomRuleInline(:final ipCidrs) => ipCidrs,
        _ => const [],
      };
  List<String> get ports => switch (this) {
        CustomRuleInline(:final ports) => ports,
        CustomRuleSrs(:final ports) => ports,
        _ => const [],
      };
  List<String> get portRanges => switch (this) {
        CustomRuleInline(:final portRanges) => portRanges,
        CustomRuleSrs(:final portRanges) => portRanges,
        _ => const [],
      };
  List<String> get packages => switch (this) {
        CustomRuleInline(:final packages) => packages,
        CustomRuleSrs(:final packages) => packages,
        _ => const [],
      };
  List<String> get protocols => switch (this) {
        CustomRuleInline(:final protocols) => protocols,
        CustomRuleSrs(:final protocols) => protocols,
        _ => const [],
      };

  /// §240 — L4-транспорт (`network`: tcp/udp/icmp). Routing-rule level
  /// (headless rule не выражает `network`), симметрично [protocols]. OR внутри
  /// списка, AND с остальным правилом.
  List<String> get network => switch (this) {
        CustomRuleInline(:final network) => network,
        CustomRuleSrs(:final network) => network,
        _ => const [],
      };
  bool get ipIsPrivate => switch (this) {
        CustomRuleInline(:final ipIsPrivate) => ipIsPrivate,
        CustomRuleSrs(:final ipIsPrivate) => ipIsPrivate,
        _ => false,
      };

  /// §030/new_fields — source-IP-CIDR (источник пакета). Эмитится в **headless
  /// rule_set** (sing-box 1.14 `DefaultHeadlessRule` принимает `source_ip_cidr`);
  /// для srs — на routing-rule level (своего headless нет). OR между собой,
  /// AND с группой назначения.
  List<String> get sourceIpCidrs => switch (this) {
        CustomRuleInline(:final sourceIpCidrs) => sourceIpCidrs,
        CustomRuleSrs(:final sourceIpCidrs) => sourceIpCidrs,
        _ => const [],
      };

  /// §030/new_fields — `source_ip_is_private`. Headless rule_set его НЕ
  /// принимает (нет в `DefaultHeadlessRule`) → всегда routing-rule level,
  /// симметрично [ipIsPrivate].
  bool get sourceIpIsPrivate => switch (this) {
        CustomRuleInline(:final sourceIpIsPrivate) => sourceIpIsPrivate,
        CustomRuleSrs(:final sourceIpIsPrivate) => sourceIpIsPrivate,
        _ => false,
      };

  /// §030/new_fields — `inbound`-ось: теги inbound'ов билдера (`tun-in`/
  /// `mixed-in`, §119). Headless rule_set `inbound` НЕ принимает → routing-rule
  /// level (как `ip_is_private`). AND с остальным правилом.
  List<String> get inbounds => switch (this) {
        CustomRuleInline(:final inbounds) => inbounds,
        CustomRuleSrs(:final inbounds) => inbounds,
        _ => const [],
      };

  /// §051 — список SSID'ов для условия `wifi_ssid` в sing-box rule. Empty —
  /// условие не эмитится. Чтение текущего ssid требует
  /// `NEARBY_WIFI_DEVICES + ACCESS_BACKGROUND_LOCATION` permission на API 33+
  /// (см. §050 findings); permission проверяется в `BoxService.startSingbox`
  /// через `cs.needWIFIState()`.
  List<String> get wifiSsids => switch (this) {
        CustomRuleInline(:final wifiSsids) => wifiSsids,
        CustomRuleSrs(:final wifiSsids) => wifiSsids,
        _ => const [],
      };

  /// §051 — список BSSID'ов (`xx:xx:xx:xx:xx:xx` lower-case). Условие
  /// `wifi_bssid` в sing-box rule.
  List<String> get wifiBssids => switch (this) {
        CustomRuleInline(:final wifiBssids) => wifiBssids,
        CustomRuleSrs(:final wifiBssids) => wifiBssids,
        _ => const [],
      };

  /// §117 задача 3 — DNS-опция правила (ортогональное поле, только
  /// inline/srs; у preset DNS-аспект живёт в `dns_options.rules` §033).
  /// `null` = выкл (backward-compat: старые записи без `dns`).
  RuleDns? get dns => switch (this) {
        CustomRuleInline(:final dns) => dns,
        CustomRuleSrs(:final dns) => dns,
        _ => null,
      };

  /// §117: правило DNS-mirror-**способно** — включено, сервер выбран, нет
  /// ports/protocols (headless-гейт: порт/протокол неизвестны в момент
  /// DNS-запроса). НЕ зависит от `dns.enabled` — строка mirror-группы видна
  /// и при выключенном DNS-аспекте (switch off, серая), чтобы его можно было
  /// включить обратно отсюда (симметрично preset-строке).
  bool get dnsMirrorEligible =>
      enabled &&
      (dns?.serverTag.isNotEmpty ?? false) &&
      ports.isEmpty &&
      portRanges.isEmpty &&
      protocols.isEmpty &&
      network.isEmpty;

  /// §117: DNS-mirror **активен** — [dnsMirrorEligible] И галка DNS включена.
  /// Build (эмиссия) и UI (lifecycle-локи серверов) используют этот предикат.
  bool get dnsMirrorActive => dnsMirrorEligible && (dns?.enabled ?? false);

  /// §256: Force IPv4 (AAAA-глушилка) **применима** — правило DNS-mirror-
  /// способно по headless-гейту (порт/протокол неизвестны в момент
  /// DNS-запроса → DNS-слой слеп), но БЕЗ требования `serverTag`: глушилка
  /// `predefined` отвечает локально, серверу не нужна. Домен / приложение
  /// (`package_name`) / source_ip — работает.
  bool get forceIpv4Eligible =>
      enabled &&
      ports.isEmpty &&
      portRanges.isEmpty &&
      protocols.isEmpty &&
      network.isEmpty;

  /// §256: Force IPv4 **активна** — [forceIpv4Eligible] И галка включена.
  /// Build (эмиссия serverless-mirror'а) и UI (маркер) используют этот предикат.
  bool get forceIpv4Active => forceIpv4Eligible && (dns?.forceIpv4 ?? false);

  /// §247 — resolve-опция правила (только inline/srs). `null` = обычный
  /// outbound (backward-compat: старые записи без `resolve`).
  RuleResolve? get resolve => switch (this) {
        CustomRuleInline(:final resolve) => resolve,
        CustomRuleSrs(:final resolve) => resolve,
        _ => null,
      };

  /// §247: правило resolve-**способно** — есть чему резолвиться. inline:
  /// domain-группа непуста (чистый ip_cidr/protocol/port-матч резолвить
  /// нечего — UI прячет шестерёнку); srs: всегда true (содержимое `.srs`
  /// не парсим — домены возможны).
  bool get resolveEligible => switch (this) {
        CustomRuleInline() => domains.isNotEmpty ||
            domainSuffixes.isNotEmpty ||
            domainKeywords.isNotEmpty,
        CustomRuleSrs() => true,
        _ => false,
      };

  /// §247: resolve **активен** — опция задана И правило resolve-способно.
  /// Билдер (эмиссия resolve-правила) и UI (✳-маркер в списке) используют
  /// этот предикат.
  bool get resolveActive => resolve != null && resolveEligible;

  String get srsUrl => switch (this) {
        CustomRuleSrs(:final srsUrl) => srsUrl,
        _ => '',
      };

  /// §225 — сырое тело json-правила. Пусто для остальных kind'ов.
  String get json => switch (this) {
        CustomRuleJson(:final json) => json,
        _ => '',
      };
  String get presetId => switch (this) {
        CustomRulePreset(:final presetId) => presetId,
        _ => '',
      };
  Map<String, String> get varsValues => switch (this) {
        CustomRulePreset(:final varsValues) => varsValues,
        _ => const {},
      };

  /// Effective outbound tag. Для `preset` возвращает **user override**
  /// `varsValues['outbound']` или пустую строку если не задан. Пустое
  /// значение в expansion означает "template-решение as is" (будь то
  /// `@outbound`-sub, hardcoded `outbound`, или shorthand `action: reject`).
  /// Непустое — universal override, заменяет template-решение любым
  /// Направлением (spec §033 Expansion §5).
  String get outbound => switch (this) {
        CustomRuleInline(:final outbound) => outbound,
        CustomRuleSrs(:final outbound) => outbound,
        CustomRulePreset(:final varsValues) => varsValues['outbound'] ?? '',
        // §225 — у json-правила действие внутри сырого тела; отдельного
        // outbound-tag нет (не участвует в OutboundPicker/dangling-миграциях).
        CustomRuleJson() => '',
      };

  /// Int-порты для sing-box (`port: [80, 443]`). Нерасспарсенное /
  /// out-of-range молча отбрасывается.
  List<int> get intPorts => ports
      .map(int.tryParse)
      .whereType<int>()
      .where((p) => p >= 0 && p <= 65535)
      .toList();

  // ─── Type-preserving mutators для UI.
  // Эти методы возвращают тот же runtime-type что у `this` (каждый subclass
  // переопределяет). Позволяют UI писать `rule.withEnabled(v)` вместо
  // `switch(rule) { case Inline() => rule.copyWith(enabled: v), ... }`.

  CustomRule withEnabled(bool enabled);
  CustomRule withName(String name);

  /// Устанавливает outbound. Для `preset` пишет в `varsValues['outbound']`,
  /// для inline/srs — в поле `outbound`.
  CustomRule withOutbound(String outbound);

  /// Фабрика — читает `j['kind']` и делегирует в `fromJson` подкласса.
  /// Backward-compat: если в JSON нет `kind`, пытается inline. Если есть
  /// старое поле `target` (до rename в 1.4.1) — читается как `outbound`.
  factory CustomRule.fromJson(Map<String, dynamic> j) {
    final kindRaw = j['kind'] as String?;
    final kind = CustomRuleKind.values.firstWhere(
      (k) => k.name == kindRaw,
      orElse: () => CustomRuleKind.inline,
    );
    final rule = switch (kind) {
      CustomRuleKind.inline => CustomRuleInline.fromJson(j),
      CustomRuleKind.srs => CustomRuleSrs.fromJson(j),
      CustomRuleKind.preset => CustomRulePreset.fromJson(j),
      CustomRuleKind.json => CustomRuleJson.fromJson(j),
    };
    // §393 B11 — транзитный груз чужих полей читается ЗДЕСЬ, одной точкой на
    // все виды правил: он одинаков у всех и к их полям отношения не имеет.
    rule.backupFields = backupFieldsFromJson(j);
    return rule;
  }
}

enum CustomRuleKind { inline, srs, preset, json }

/// §117 задача 3 — DNS-опция правила («DNS follows the rule»). Правило
/// **ссылается** на существующий DNS-сервер по tag (выбор из списка, не ввод
/// адреса — locked decision №2); detour сервера — зона задач 1/2, правило
/// его не трогает (№1). `enabled: false` сохраняет выбранный `serverTag`,
/// чтобы повторное включение не теряло выбор.
class RuleDns {
  const RuleDns({
    this.enabled = false,
    this.serverTag = '',
    this.forceIpv4 = false,
  });

  final bool enabled;
  final String serverTag;

  /// §256 — Force IPv4: гасить AAAA (IPv6) для матча правила пустым
  /// authoritative-ответом (`ip_version: 6, action: predefined, rcode:
  /// NOERROR`), приложение чисто берёт A. Ортогонально [enabled]/[serverTag]
  /// — глушилка отвечает локально, DNS-серверу не нужна.
  final bool forceIpv4;

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'serverTag': serverTag,
        if (forceIpv4) 'forceIpv4': true,
      };

  /// Backward-compat: не-Map (отсутствует в старых записях) → null.
  static RuleDns? fromJson(dynamic j) {
    if (j is! Map) return null;
    return RuleDns(
      enabled: j['enabled'] == true,
      serverTag: j['serverTag']?.toString() ?? '',
      forceIpv4: j['forceIpv4'] == true,
    );
  }

  RuleDns copyWith({bool? enabled, String? serverTag, bool? forceIpv4}) =>
      RuleDns(
        enabled: enabled ?? this.enabled,
        serverTag: serverTag ?? this.serverTag,
        forceIpv4: forceIpv4 ?? this.forceIpv4,
      );
}

/// §247 — resolve-опция правила (route rule action `resolve`, sing-box 1.14).
/// `null` на правиле = обычный outbound (backward-compat: старые записи).
///
/// Два режима:
/// - `only == false` — **route + resolve**: билдер эмитит ДВА правила —
///   нетерминальный resolve ПЕРЕД терминальным route (тот же матч);
/// - `only == true` — **resolve only** (advanced): одно нетерминальное
///   правило; трафик проваливается к следующим правилам / route.final.
///   `outbound` правила при этом сохраняется в модели (переключение
///   режимов не теряет выбор), но билдером игнорируется.
///
/// Пустая строка / null у опциональных полей = ключ не эмитится
/// (минимальный конфиг, дефолты ядра).
class RuleResolve {
  const RuleResolve({
    this.only = false,
    this.strategy = '',
    this.serverTag = '',
    this.disableCache = false,
    this.disableOptimisticCache = false,
    this.rewriteTtl,
    this.timeout = '',
    this.clientSubnet = '',
  });

  final bool only;

  /// '' = inherit `dns.strategy`; иначе prefer_ipv4/prefer_ipv6/ipv4_only/ipv6_only.
  final String strategy;

  /// '' = auto (резолв через DNS-роутинг); иначе tag DNS-сервера.
  final String serverTag;

  final bool disableCache;
  final bool disableOptimisticCache;

  /// null = не эмитить. sing-box: uint32.
  final int? rewriteTtl;

  /// '' = не эмитить. Duration-строка sing-box ('5s', '500ms').
  final String timeout;

  /// '' = не эмитить. CIDR/IP для edns0-subnet.
  final String clientSubnet;

  Map<String, dynamic> toJson() => {
        'only': only,
        if (strategy.isNotEmpty) 'strategy': strategy,
        if (serverTag.isNotEmpty) 'serverTag': serverTag,
        if (disableCache) 'disableCache': true,
        if (disableOptimisticCache) 'disableOptimisticCache': true,
        if (rewriteTtl != null) 'rewriteTtl': rewriteTtl,
        if (timeout.isNotEmpty) 'timeout': timeout,
        if (clientSubnet.isNotEmpty) 'clientSubnet': clientSubnet,
      };

  /// Backward-compat: не-Map (отсутствует в старых записях) → null.
  static RuleResolve? fromJson(dynamic j) {
    if (j is! Map) return null;
    return RuleResolve(
      only: j['only'] == true,
      strategy: j['strategy']?.toString() ?? '',
      serverTag: j['serverTag']?.toString() ?? '',
      disableCache: j['disableCache'] == true,
      disableOptimisticCache: j['disableOptimisticCache'] == true,
      rewriteTtl: switch (j['rewriteTtl']) {
        final int v when v >= 0 => v,
        final String s => int.tryParse(s),
        _ => null,
      },
      timeout: j['timeout']?.toString() ?? '',
      clientSubnet: j['clientSubnet']?.toString() ?? '',
    );
  }

  RuleResolve copyWith({
    bool? only,
    String? strategy,
    String? serverTag,
    bool? disableCache,
    bool? disableOptimisticCache,
    int? rewriteTtl,
    bool clearRewriteTtl = false,
    String? timeout,
    String? clientSubnet,
  }) =>
      RuleResolve(
        only: only ?? this.only,
        strategy: strategy ?? this.strategy,
        serverTag: serverTag ?? this.serverTag,
        disableCache: disableCache ?? this.disableCache,
        disableOptimisticCache:
            disableOptimisticCache ?? this.disableOptimisticCache,
        rewriteTtl: clearRewriteTtl ? null : (rewriteTtl ?? this.rewriteTtl),
        timeout: timeout ?? this.timeout,
        clientSubnet: clientSubnet ?? this.clientSubnet,
      );
}

/// Sentinel-значение для `CustomRuleInline.outbound` / `CustomRuleSrs.outbound`.
/// Билдер матчит на `{action: "reject"}` вместо `{outbound: <tag>}`. sing-box
/// не имеет outbound'а с таким именем — коллизий нет.
const String kOutboundReject = 'reject';

/// Известные L7-протоколы для sing-box `protocol` field. Применяется на
/// routing-rule уровне (headless rule не поддерживает `protocol`).
/// Актуально для sing-box 1.12.x.
const List<String> kKnownProtocols = [
  'bittorrent',
  'dns',
  'dtls',
  'http',
  'ntp',
  'quic',
  'rdp',
  'ssh',
  'stun',
  'tls',
];

/// §240 — L4-транспорты для sing-box `network` field (route-rule level).
/// Закрытый набор: по документации допустимы ровно `tcp`, `udp`, `icmp`
/// (нет `icmpv6`, нет отдельного `ip_protocol`).
const List<String> kKnownNetworks = [
  'tcp',
  'udp',
  'icmp',
];

// ─── Inline ────────────────────────────────────────────────────────────

/// Inline правило — юзер ввёл match-поля через «+ Add rule». Билдер
/// собирает headless rule с OR-семантикой внутри category, AND между.
///
/// Per sing-box default rule matching: одно правило с
/// `domainSuffixes=[.ru], ports=[443], packages=[...firefox]` матчится как
/// `(domain_suffix == .ru) && (port == 443) && (package_name == ...firefox)`.
/// `protocols` и `ipIsPrivate` не поддерживаются в headless — билдер
/// выносит их на routing-rule level.
class CustomRuleInline extends CustomRule {
  CustomRuleInline({
    super.id,
    required super.name,
    super.enabled = true,
    super.orderNum,
    this.domains = const [],
    this.domainSuffixes = const [],
    this.domainKeywords = const [],
    this.ipCidrs = const [],
    this.ports = const [],
    this.portRanges = const [],
    this.packages = const [],
    this.protocols = const [],
    this.network = const [],
    this.ipIsPrivate = false,
    this.sourceIpCidrs = const [],
    this.sourceIpIsPrivate = false,
    this.inbounds = const [],
    this.wifiSsids = const [],
    List<String> wifiBssids = const [],
    this.outbound = kDirectOutboundTag,
    this.dns,
    this.resolve,
  }) : wifiBssids = _normalizeBssids(wifiBssids);

  // OR-группа #1 (domain-family + ip). Внутри OR, между остальными — AND.
  @override
  List<String> domains;
  @override
  List<String> domainSuffixes;
  @override
  List<String> domainKeywords;
  @override
  List<String> ipCidrs;

  // OR-группа #2 (port-family). AND с domain-family.
  @override
  List<String> ports;       // user-input, int-parse на emit
  @override
  List<String> portRanges;  // "8000:9000", ":3000", "4000:"

  // OR-группа #3 (package_name). AND с остальными.
  @override
  List<String> packages;

  // Routing-rule-level AND (не в headless).
  @override
  List<String> protocols;   // subset of kKnownProtocols
  /// §240 — L4-транспорт (subset of kKnownNetworks). Routing-rule level.
  @override
  List<String> network;
  @override
  bool ipIsPrivate;

  /// §030/new_fields — source-IP-CIDR. В headless `match` (sing-box 1.14
  /// принимает). OR между собой, AND с domain/port-группами.
  @override
  List<String> sourceIpCidrs;

  /// §030/new_fields — `source_ip_is_private`. Routing-rule level (headless
  /// не принимает), симметрично [ipIsPrivate].
  @override
  bool sourceIpIsPrivate;

  /// §030/new_fields — `inbound` (теги `tun-in`/`mixed-in`, §119). Routing-rule
  /// level (headless не принимает). AND с остальным.
  @override
  List<String> inbounds;

  /// §051 — wifi-условия. С sing-box 1.14 эмитятся в **headless rule_set**
  /// (`DefaultHeadlessRule.wifi_ssid/wifi_bssid`); для srs остаются на
  /// routing-rule level. AND с остальным match.
  @override
  List<String> wifiSsids;
  @override
  List<String> wifiBssids;

  /// Outbound-тег либо `kOutboundReject` (→ action: reject).
  @override
  String outbound;

  /// §117 задача 3 — DNS-опция (mirror DNS-rule на выбранный сервер).
  @override
  RuleDns? dns;

  /// §247 — resolve-опция (route action `resolve` перед/вместо route).
  @override
  RuleResolve? resolve;

  @override
  CustomRuleKind get kind => CustomRuleKind.inline;

  @override
  String summary() {
    final parts = <String>[];
    if (domains.isNotEmpty) parts.add(getLocalText.plural("%d domains", domains.length));
    if (domainSuffixes.isNotEmpty) {
      parts.add(getLocalText.plural("%d suffixes", domainSuffixes.length));
    }
    if (domainKeywords.isNotEmpty) {
      parts.add(getLocalText.plural("%d keywords", domainKeywords.length));
    }
    if (ipCidrs.isNotEmpty) parts.add(getLocalText.plural("%d cidrs", ipCidrs.length));
    if (ipIsPrivate) parts.add(getLocalText.s("private ip"));
    if (sourceIpCidrs.isNotEmpty) {
      parts.add(getLocalText.plural("%d src", sourceIpCidrs.length));
    }
    if (sourceIpIsPrivate) parts.add(getLocalText.s("private src"));
    final totalPorts = ports.length + portRanges.length;
    if (totalPorts > 0) parts.add(getLocalText.plural("%d ports", totalPorts));
    if (packages.isNotEmpty) parts.add(getLocalText.plural("%d apps", packages.length));
    if (protocols.isNotEmpty) parts.add(getLocalText.plural("%d proto", protocols.length));
    if (network.isNotEmpty) parts.add(getLocalText.plural("%d net", network.length));
    if (inbounds.isNotEmpty) parts.add(getLocalText.s("%d in", inbounds.length));
    if (wifiSsids.isNotEmpty) parts.add(getLocalText.s("%d wifi", wifiSsids.length));
    return parts.join(' · ');
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'kind': kind.name,
        if (orderNum != null) 'num': orderNum,
        if (domains.isNotEmpty) 'domains': domains,
        if (domainSuffixes.isNotEmpty) 'domainSuffixes': domainSuffixes,
        if (domainKeywords.isNotEmpty) 'domainKeywords': domainKeywords,
        if (ipCidrs.isNotEmpty) 'ipCidrs': ipCidrs,
        if (ports.isNotEmpty) 'ports': ports,
        if (portRanges.isNotEmpty) 'portRanges': portRanges,
        if (packages.isNotEmpty) 'packages': packages,
        if (protocols.isNotEmpty) 'protocols': protocols,
        if (network.isNotEmpty) 'network': network,
        if (ipIsPrivate) 'ipIsPrivate': true,
        if (sourceIpCidrs.isNotEmpty) 'sourceIpCidrs': sourceIpCidrs,
        if (sourceIpIsPrivate) 'sourceIpIsPrivate': true,
        if (inbounds.isNotEmpty) 'inbounds': inbounds,
        if (wifiSsids.isNotEmpty) 'wifiSsids': wifiSsids,
        if (wifiBssids.isNotEmpty) 'wifiBssids': wifiBssids,
        'outbound': outbound,
        if (dns != null) 'dns': dns!.toJson(),
        if (resolve != null) 'resolve': resolve!.toJson(),
        // §393 B11 — транзитный груз полей чужой схемы (см. [backupFields]).
        ...backupFieldsJson,
      };

  factory CustomRuleInline.fromJson(Map<String, dynamic> j) => CustomRuleInline(
        id: _id(j),
        name: (j['name'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        orderNum: j['num'] as int?,
        domains: _stringList(j['domains']),
        domainSuffixes: _stringList(j['domainSuffixes']),
        domainKeywords: _stringList(j['domainKeywords']),
        ipCidrs: _stringList(j['ipCidrs']),
        ports: _stringList(j['ports']),
        portRanges: _stringList(j['portRanges']),
        packages: _stringList(j['packages']),
        protocols: _stringList(j['protocols']),
        network: _stringList(j['network']),
        ipIsPrivate: (j['ipIsPrivate'] as bool?) ?? false,
        sourceIpCidrs: _stringList(j['sourceIpCidrs']),
        sourceIpIsPrivate: (j['sourceIpIsPrivate'] as bool?) ?? false,
        inbounds: _stringList(j['inbounds']),
        wifiSsids: _stringList(j['wifiSsids']),
        wifiBssids: _stringList(j['wifiBssids']),
        outbound: _outbound(j),
        dns: RuleDns.fromJson(j['dns']),
        resolve: RuleResolve.fromJson(j['resolve']),
      );

  CustomRuleInline copyWith({
    String? name,
    bool? enabled,
    int? orderNum,
    List<String>? domains,
    List<String>? domainSuffixes,
    List<String>? domainKeywords,
    List<String>? ipCidrs,
    List<String>? ports,
    List<String>? portRanges,
    List<String>? packages,
    List<String>? protocols,
    List<String>? network,
    bool? ipIsPrivate,
    List<String>? sourceIpCidrs,
    bool? sourceIpIsPrivate,
    List<String>? inbounds,
    List<String>? wifiSsids,
    List<String>? wifiBssids,
    String? outbound,
    RuleDns? dns,
    // §257: `dns ?? this.dns` не позволяет обнулить — явный флаг (паттерн
    // clearRewriteTtl в RuleResolve.copyWith). DNS Settings обнуляет dns,
    // когда сняты оба аспекта (не копить мёртвый RuleDns{}).
    bool clearDns = false,
    RuleResolve? resolve,
  }) =>
      // §393 B11 — транзитный груз переезжает на копию: он не поле модели, и
      // без явного переноса терялся бы на любой правке правила.
      CustomRule.carryBackupFields(
          CustomRuleInline(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        orderNum: orderNum ?? this.orderNum,
        domains: domains ?? this.domains,
        domainSuffixes: domainSuffixes ?? this.domainSuffixes,
        domainKeywords: domainKeywords ?? this.domainKeywords,
        ipCidrs: ipCidrs ?? this.ipCidrs,
        ports: ports ?? this.ports,
        portRanges: portRanges ?? this.portRanges,
        packages: packages ?? this.packages,
        protocols: protocols ?? this.protocols,
        network: network ?? this.network,
        ipIsPrivate: ipIsPrivate ?? this.ipIsPrivate,
        sourceIpCidrs: sourceIpCidrs ?? this.sourceIpCidrs,
        sourceIpIsPrivate: sourceIpIsPrivate ?? this.sourceIpIsPrivate,
        inbounds: inbounds ?? this.inbounds,
        wifiSsids: wifiSsids ?? this.wifiSsids,
        wifiBssids: wifiBssids ?? this.wifiBssids,
        outbound: outbound ?? this.outbound,
        dns: clearDns ? null : (dns ?? this.dns),
        resolve: resolve ?? this.resolve,
      ), this);

  @override
  CustomRuleInline withEnabled(bool enabled) => copyWith(enabled: enabled);
  @override
  CustomRuleInline withName(String name) => copyWith(name: name);
  @override
  CustomRuleInline withOutbound(String outbound) => copyWith(outbound: outbound);
}

// ─── Srs ───────────────────────────────────────────────────────────────

/// Локально закэшированный `.srs`-бинарь по URL (spec §011). Юзер качает
/// через ☁-кнопку в UI; sing-box получает `type: local, path: <кэш>` — URL
/// в конфиг не попадает, никакого auto-download.
class CustomRuleSrs extends CustomRule {
  CustomRuleSrs({
    super.id,
    required super.name,
    super.enabled = true,
    super.orderNum,
    this.srsUrl = '',
    this.ports = const [],
    this.portRanges = const [],
    this.packages = const [],
    this.protocols = const [],
    this.network = const [],
    this.ipIsPrivate = false,
    this.sourceIpCidrs = const [],
    this.sourceIpIsPrivate = false,
    this.inbounds = const [],
    this.wifiSsids = const [],
    List<String> wifiBssids = const [],
    this.outbound = kDirectOutboundTag,
    this.dns,
    this.resolve,
    this.updateIntervalHours = kDefaultSrsTtlHours,
  }) : wifiBssids = _normalizeBssids(wifiBssids);

  @override
  String srsUrl;

  /// §366 — через сколько часов кэш считается протухшим. Авто-обновление
  /// (`RuleSetAutoUpdater`) берёт TTL отсюда; `0` = не обновлять
  /// автоматически (ручной ⟳ работает всегда). Значения — из
  /// [kSrsTtlChoicesHours], в UI выпадающий список.
  int updateIntervalHours;

  /// Доп-фильтры на routing-rule level (AND с `.srs`-match внутри rule_set).
  /// Используются когда remote `.srs` слишком широкий: например, «только
  /// на 443 + только Firefox».
  @override
  List<String> ports;
  @override
  List<String> portRanges;
  @override
  List<String> packages;
  @override
  List<String> protocols;
  /// §240 — L4-транспорт (subset of kKnownNetworks). Routing-rule level.
  @override
  List<String> network;
  @override
  bool ipIsPrivate;

  /// §030/new_fields — source/inbound доп-фильтры. У srs нет своего headless
  /// `match` (rule_set внешний) → ВСЕ эти поля эмитятся на routing-rule level
  /// (включая `source_ip_cidr` — в отличие от inline, где он в headless).
  @override
  List<String> sourceIpCidrs;
  @override
  bool sourceIpIsPrivate;
  @override
  List<String> inbounds;

  /// §051 — wifi-условия. Для srs — routing-rule level (своего headless нет).
  @override
  List<String> wifiSsids;
  @override
  List<String> wifiBssids;

  @override
  String outbound;

  /// §117 задача 3 — DNS-опция. Серая пометка в UI: mirror работает, только
  /// если в `.srs` есть домены (содержимое бинаря не парсим — IP-only лист
  /// в DNS-контексте молча не сматчит).
  @override
  RuleDns? dns;

  /// §247 — resolve-опция. Для srs всегда eligible (домены в `.srs`
  /// возможны, содержимое не парсим — симметрично dns-пометке выше).
  @override
  RuleResolve? resolve;

  @override
  CustomRuleKind get kind => CustomRuleKind.srs;

  @override
  String summary() {
    if (srsUrl.trim().isEmpty) return '';
    final host = Uri.tryParse(srsUrl)?.host;
    return getLocalText.s("SRS: %s", host?.isNotEmpty == true ? host! : srsUrl);
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'kind': kind.name,
        if (orderNum != null) 'num': orderNum,
        if (srsUrl.isNotEmpty) 'srsUrl': srsUrl,
        if (ports.isNotEmpty) 'ports': ports,
        if (portRanges.isNotEmpty) 'portRanges': portRanges,
        if (packages.isNotEmpty) 'packages': packages,
        if (protocols.isNotEmpty) 'protocols': protocols,
        if (network.isNotEmpty) 'network': network,
        if (ipIsPrivate) 'ipIsPrivate': true,
        if (sourceIpCidrs.isNotEmpty) 'sourceIpCidrs': sourceIpCidrs,
        if (sourceIpIsPrivate) 'sourceIpIsPrivate': true,
        if (inbounds.isNotEmpty) 'inbounds': inbounds,
        if (wifiSsids.isNotEmpty) 'wifiSsids': wifiSsids,
        if (wifiBssids.isNotEmpty) 'wifiBssids': wifiBssids,
        'outbound': outbound,
        if (dns != null) 'dns': dns!.toJson(),
        if (resolve != null) 'resolve': resolve!.toJson(),
        // §366 — дефолт не пишем: старые правила без ключа читаются как
        // «неделя», и JSON не растёт на каждом правиле ради значения,
        // которое и так подразумевается.
        if (updateIntervalHours != kDefaultSrsTtlHours)
          'updateIntervalHours': updateIntervalHours,
        ...backupFieldsJson,
      };

  factory CustomRuleSrs.fromJson(Map<String, dynamic> j) => CustomRuleSrs(
        id: _id(j),
        name: (j['name'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        orderNum: j['num'] as int?,
        srsUrl: (j['srsUrl'] as String?) ?? '',
        ports: _stringList(j['ports']),
        portRanges: _stringList(j['portRanges']),
        packages: _stringList(j['packages']),
        protocols: _stringList(j['protocols']),
        network: _stringList(j['network']),
        ipIsPrivate: (j['ipIsPrivate'] as bool?) ?? false,
        sourceIpCidrs: _stringList(j['sourceIpCidrs']),
        sourceIpIsPrivate: (j['sourceIpIsPrivate'] as bool?) ?? false,
        inbounds: _stringList(j['inbounds']),
        wifiSsids: _stringList(j['wifiSsids']),
        wifiBssids: _stringList(j['wifiBssids']),
        outbound: _outbound(j),
        dns: RuleDns.fromJson(j['dns']),
        resolve: RuleResolve.fromJson(j['resolve']),
        updateIntervalHours: _srsTtl(j['updateIntervalHours']),
      );

  /// §366 — TTL из JSON. Отсутствие, мусор и отрицательные значения → дефолт;
  /// `0` (Never) сохраняем как есть, это осознанный выбор юзера.
  static int _srsTtl(dynamic v) {
    final n = v is num ? v.toInt() : null;
    if (n == null || n < 0) return kDefaultSrsTtlHours;
    return n;
  }

  CustomRuleSrs copyWith({
    String? name,
    bool? enabled,
    int? orderNum,
    String? srsUrl,
    List<String>? ports,
    List<String>? portRanges,
    List<String>? packages,
    List<String>? protocols,
    List<String>? network,
    bool? ipIsPrivate,
    List<String>? sourceIpCidrs,
    bool? sourceIpIsPrivate,
    List<String>? inbounds,
    List<String>? wifiSsids,
    List<String>? wifiBssids,
    String? outbound,
    RuleDns? dns,
    bool clearDns = false, // §257 — см. CustomRuleInline.copyWith
    RuleResolve? resolve,
    int? updateIntervalHours,
  }) =>
      CustomRule.carryBackupFields(
          CustomRuleSrs(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        orderNum: orderNum ?? this.orderNum,
        srsUrl: srsUrl ?? this.srsUrl,
        ports: ports ?? this.ports,
        portRanges: portRanges ?? this.portRanges,
        packages: packages ?? this.packages,
        protocols: protocols ?? this.protocols,
        network: network ?? this.network,
        ipIsPrivate: ipIsPrivate ?? this.ipIsPrivate,
        sourceIpCidrs: sourceIpCidrs ?? this.sourceIpCidrs,
        sourceIpIsPrivate: sourceIpIsPrivate ?? this.sourceIpIsPrivate,
        inbounds: inbounds ?? this.inbounds,
        wifiSsids: wifiSsids ?? this.wifiSsids,
        wifiBssids: wifiBssids ?? this.wifiBssids,
        outbound: outbound ?? this.outbound,
        dns: clearDns ? null : (dns ?? this.dns),
        resolve: resolve ?? this.resolve,
        updateIntervalHours:
            updateIntervalHours ?? this.updateIntervalHours,
      ), this);

  @override
  CustomRuleSrs withEnabled(bool enabled) => copyWith(enabled: enabled);
  @override
  CustomRuleSrs withName(String name) => copyWith(name: name);
  @override
  CustomRuleSrs withOutbound(String outbound) => copyWith(outbound: outbound);
}

// ─── Preset (bundle thin reference) ────────────────────────────────────

/// Тонкая ссылка на `SelectableRule(presetId=...)` в шаблоне (spec §033).
/// Хранит только `{presetId, varsValues}` — всё остальное разворачивается
/// при каждом `buildConfig` через `expandPreset`. Обновил шаблон → новое
/// поведение у всех юзеров.
///
/// `name` хранится snapshot'ом `preset.label`, но в UI редакторе
/// **read-only** (🔒). Билдер периодически обновляет snapshot из текущего
/// шаблона, так что переименование пресета дойдёт до существующих правил.
///
/// `outbound` нет как отдельного поля — значение `varsValues['outbound']`
/// подставляется в шаблонный `@outbound`-плейсхолдер при expansion.
class CustomRulePreset extends CustomRule {
  CustomRulePreset({
    super.id,
    required super.name,
    super.enabled = true,
    super.orderNum,
    required this.presetId,
    Map<String, String>? varsValues,
  }) : varsValues = Map<String, String>.from(varsValues ?? const {});

  @override
  String presetId;

  /// Значения переменных пресета, выставленные юзером в UI.
  ///
  /// Семантика (spec §033 expansion):
  /// - ключ **отсутствует** → юзер не трогал контрол → применяется
  ///   `default_value` из шаблона.
  /// - ключ **есть, значение непустое** → явный выбор.
  /// - ключ **есть, значение пустое** → explicit "— (none)" для optional var;
  ///   фрагменты с unresolved `@name` выкидываются.
  @override
  Map<String, String> varsValues;

  @override
  CustomRuleKind get kind => CustomRuleKind.preset;

  @override
  String summary() {
    // Preset-факт уже виден в UI — read-only `name` (snapshot template-label'а)
    // плюс 🔒 иконка. Дублировать «preset: <id>» в subtitle не нужно.
    // Показываем только user-выставленные vars (если есть и непусты).
    // `l` не нужен: var-имена/значения — wire-данные, не переводятся.
    if (presetId.isEmpty) return '';
    if (varsValues.isEmpty) return '';
    return varsValues.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => '${e.key}=${e.value}')
        .take(2)
        .join(', ');
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'kind': kind.name,
        if (orderNum != null) 'num': orderNum,
        'presetId': presetId,
        if (varsValues.isNotEmpty) 'varsValues': varsValues,
        ...backupFieldsJson,
      };

  factory CustomRulePreset.fromJson(Map<String, dynamic> j) => CustomRulePreset(
        id: _id(j),
        name: (j['name'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        orderNum: j['num'] as int?,
        presetId: (j['presetId'] as String?) ?? '',
        varsValues: _stringMap(j['varsValues']),
      );

  CustomRulePreset copyWith({
    String? name,
    bool? enabled,
    int? orderNum,
    String? presetId,
    Map<String, String>? varsValues,
  }) =>
      CustomRule.carryBackupFields(
          CustomRulePreset(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        orderNum: orderNum ?? this.orderNum,
        presetId: presetId ?? this.presetId,
        varsValues: varsValues ?? this.varsValues,
      ), this);

  @override
  CustomRulePreset withEnabled(bool enabled) => copyWith(enabled: enabled);
  @override
  CustomRulePreset withName(String name) => copyWith(name: name);

  /// Для preset outbound хранится в `varsValues['outbound']`. Применяется
  /// в `preset_expand` как **universal override**: полностью заменяет
  /// template-решение независимо от того, задан в шаблоне `@outbound`,
  /// hardcoded `outbound: "<tag>"` или shorthand `action: "reject"`.
  /// Юзер может переключить Block Ads с reject на vpn-1, и наоборот любой
  /// Направление на reject. См. spec §033 Expansion §5 "Universal outbound override".
  @override
  CustomRulePreset withOutbound(String outbound) {
    final updated = Map<String, String>.from(varsValues);
    updated['outbound'] = outbound;
    return copyWith(varsValues: updated);
  }
}

// ─── Raw JSON (§225) ─────────────────────────────────────────────────────

/// §225 (#17) — правило заданное сырым JSON. Юзер пишет тело правила (или
/// массив тел) для `route.rules`, билдер кладёт его как есть — это открывает
/// ЛЮБОЙ sing-box route-action (`hijack-dns`/`sniff`/`resolve`/`route-options`
/// и т.д.) без модели-на-каждое-поле. Действие — часть самого JSON, поэтому
/// `outbound` отсутствует, а match-секции UI (domain/port/wifi/dns) скрыты.
///
/// `json` хранится как ввёл юзер (не переформатируем). Валидность синтаксиса
/// проверяется в UI (inline) и в билдере (skip+warning на битом JSON, без
/// падения сборки). Dangling `outbound` внутри тела ловит `validateConfig`
/// тем же путём, что и обычные правила.
class CustomRuleJson extends CustomRule {
  CustomRuleJson({
    super.id,
    required super.name,
    super.enabled = true,
    super.orderNum,
    this.json = '',
  });

  /// Сырой текст правила: JSON-объект `{...}` или массив объектов `[{...}]`.
  @override
  final String json;

  @override
  CustomRuleKind get kind => CustomRuleKind.json;

  @override
  String summary() {
    // `l` не нужен: сырой JSON — wire-данные, не переводятся.
    final oneLine = json.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.isEmpty) return '';
    return oneLine.length <= 48 ? oneLine : '${oneLine.substring(0, 48)}…';
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'kind': kind.name,
        if (orderNum != null) 'num': orderNum,
        'json': json,
        ...backupFieldsJson,
      };

  factory CustomRuleJson.fromJson(Map<String, dynamic> j) => CustomRuleJson(
        id: _id(j),
        name: (j['name'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        orderNum: j['num'] as int?,
        json: (j['json'] as String?) ?? '',
      );

  CustomRuleJson copyWith({String? name, bool? enabled, int? orderNum, String? json}) =>
      CustomRule.carryBackupFields(
          CustomRuleJson(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        orderNum: orderNum ?? this.orderNum,
        json: json ?? this.json,
      ), this);

  @override
  CustomRuleJson withEnabled(bool enabled) => copyWith(enabled: enabled);
  @override
  CustomRuleJson withName(String name) => copyWith(name: name);

  /// json-правило не имеет outbound-поля (действие внутри тела) — no-op.
  @override
  CustomRuleJson withOutbound(String outbound) => this;
}

// ─── helpers ───────────────────────────────────────────────────────────

String? _id(Map<String, dynamic> j) {
  final id = j['id'] as String?;
  return (id?.trim().isNotEmpty ?? false) ? id : null;
}

/// Читает `outbound`, fallback на legacy-поле `target` (до 1.4.1 rename).
String _outbound(Map<String, dynamic> j) =>
    (j['outbound'] as String?) ?? (j['target'] as String?) ?? kDirectOutboundTag;

List<String> _stringList(dynamic v) {
  if (v is! List) return const [];
  return v.map((e) => e.toString()).toList();
}

/// §051 — нормализует BSSID к lower-case формату `xx:xx:xx:xx:xx:xx`.
/// Юзер мог ввести uppercase из браузера/`adb shell` — sing-box матчит
/// case-sensitive по строкам. Здесь tolerant'но lower-case'им и trim'аем,
/// строгую regex-валидацию делает Debug API parser (на write-side).
List<String> _normalizeBssids(List<String> bssids) {
  if (bssids.isEmpty) return const [];
  return bssids.map((b) => b.trim().toLowerCase()).toList(growable: false);
}

Map<String, String> _stringMap(dynamic v) {
  if (v is! Map) return const {};
  return {
    for (final e in v.entries)
      if (e.key is String) e.key as String: e.value?.toString() ?? '',
  };
}
