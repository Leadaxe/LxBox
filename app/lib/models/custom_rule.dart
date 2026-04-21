import '../services/parser/uri_utils.dart' show newUuidV4;

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
sealed class CustomRule {
  CustomRule({
    String? id,
    required this.name,
    required this.enabled,
  }) : id = id ?? newUuidV4();

  final String id;
  String name;
  bool enabled;

  /// Enum-дискриминатор для JSON. Значения совпадают с именами подклассов
  /// по convention (inline/srs/preset).
  CustomRuleKind get kind;

  Map<String, dynamic> toJson();

  /// Короткая сводка для subtitle на RoutingScreen. Пустая → UI покажет
  /// заглушку "Tap to edit".
  String get summary;

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
  bool get ipIsPrivate => switch (this) {
        CustomRuleInline(:final ipIsPrivate) => ipIsPrivate,
        CustomRuleSrs(:final ipIsPrivate) => ipIsPrivate,
        _ => false,
      };
  String get srsUrl => switch (this) {
        CustomRuleSrs(:final srsUrl) => srsUrl,
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
  /// каналом (spec §033 Expansion §5).
  String get outbound => switch (this) {
        CustomRuleInline(:final outbound) => outbound,
        CustomRuleSrs(:final outbound) => outbound,
        CustomRulePreset(:final varsValues) => varsValues['outbound'] ?? '',
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
    return switch (kind) {
      CustomRuleKind.inline => CustomRuleInline.fromJson(j),
      CustomRuleKind.srs => CustomRuleSrs.fromJson(j),
      CustomRuleKind.preset => CustomRulePreset.fromJson(j),
    };
  }
}

enum CustomRuleKind { inline, srs, preset }

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
    this.domains = const [],
    this.domainSuffixes = const [],
    this.domainKeywords = const [],
    this.ipCidrs = const [],
    this.ports = const [],
    this.portRanges = const [],
    this.packages = const [],
    this.protocols = const [],
    this.ipIsPrivate = false,
    this.outbound = 'direct-out',
  });

  // OR-группа #1 (domain-family + ip). Внутри OR, между остальными — AND.
  List<String> domains;
  List<String> domainSuffixes;
  List<String> domainKeywords;
  List<String> ipCidrs;

  // OR-группа #2 (port-family). AND с domain-family.
  List<String> ports;       // user-input, int-parse на emit
  List<String> portRanges;  // "8000:9000", ":3000", "4000:"

  // OR-группа #3 (package_name). AND с остальными.
  List<String> packages;

  // Routing-rule-level AND (не в headless).
  List<String> protocols;   // subset of kKnownProtocols
  bool ipIsPrivate;

  /// Outbound-тег либо `kOutboundReject` (→ action: reject).
  String outbound;

  @override
  CustomRuleKind get kind => CustomRuleKind.inline;

  @override
  String get summary {
    final parts = <String>[];
    if (domains.isNotEmpty) parts.add('${domains.length} domain');
    if (domainSuffixes.isNotEmpty) parts.add('${domainSuffixes.length} suffix');
    if (domainKeywords.isNotEmpty) parts.add('${domainKeywords.length} keyword');
    if (ipCidrs.isNotEmpty) parts.add('${ipCidrs.length} cidr');
    if (ipIsPrivate) parts.add('private ip');
    final totalPorts = ports.length + portRanges.length;
    if (totalPorts > 0) parts.add('$totalPorts port');
    if (packages.isNotEmpty) parts.add('${packages.length} app');
    if (protocols.isNotEmpty) parts.add('${protocols.length} proto');
    return parts.join(' · ');
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'kind': kind.name,
        if (domains.isNotEmpty) 'domains': domains,
        if (domainSuffixes.isNotEmpty) 'domainSuffixes': domainSuffixes,
        if (domainKeywords.isNotEmpty) 'domainKeywords': domainKeywords,
        if (ipCidrs.isNotEmpty) 'ipCidrs': ipCidrs,
        if (ports.isNotEmpty) 'ports': ports,
        if (portRanges.isNotEmpty) 'portRanges': portRanges,
        if (packages.isNotEmpty) 'packages': packages,
        if (protocols.isNotEmpty) 'protocols': protocols,
        if (ipIsPrivate) 'ipIsPrivate': true,
        'outbound': outbound,
      };

  factory CustomRuleInline.fromJson(Map<String, dynamic> j) => CustomRuleInline(
        id: _id(j),
        name: (j['name'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        domains: _stringList(j['domains']),
        domainSuffixes: _stringList(j['domainSuffixes']),
        domainKeywords: _stringList(j['domainKeywords']),
        ipCidrs: _stringList(j['ipCidrs']),
        ports: _stringList(j['ports']),
        portRanges: _stringList(j['portRanges']),
        packages: _stringList(j['packages']),
        protocols: _stringList(j['protocols']),
        ipIsPrivate: (j['ipIsPrivate'] as bool?) ?? false,
        outbound: _outbound(j),
      );

  CustomRuleInline copyWith({
    String? name,
    bool? enabled,
    List<String>? domains,
    List<String>? domainSuffixes,
    List<String>? domainKeywords,
    List<String>? ipCidrs,
    List<String>? ports,
    List<String>? portRanges,
    List<String>? packages,
    List<String>? protocols,
    bool? ipIsPrivate,
    String? outbound,
  }) =>
      CustomRuleInline(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        domains: domains ?? this.domains,
        domainSuffixes: domainSuffixes ?? this.domainSuffixes,
        domainKeywords: domainKeywords ?? this.domainKeywords,
        ipCidrs: ipCidrs ?? this.ipCidrs,
        ports: ports ?? this.ports,
        portRanges: portRanges ?? this.portRanges,
        packages: packages ?? this.packages,
        protocols: protocols ?? this.protocols,
        ipIsPrivate: ipIsPrivate ?? this.ipIsPrivate,
        outbound: outbound ?? this.outbound,
      );

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
    this.srsUrl = '',
    this.ports = const [],
    this.portRanges = const [],
    this.packages = const [],
    this.protocols = const [],
    this.ipIsPrivate = false,
    this.outbound = 'direct-out',
  });

  String srsUrl;

  /// Доп-фильтры на routing-rule level (AND с `.srs`-match внутри rule_set).
  /// Используются когда remote `.srs` слишком широкий: например, «только
  /// на 443 + только Firefox».
  List<String> ports;
  List<String> portRanges;
  List<String> packages;
  List<String> protocols;
  bool ipIsPrivate;

  String outbound;

  @override
  CustomRuleKind get kind => CustomRuleKind.srs;

  @override
  String get summary {
    if (srsUrl.trim().isEmpty) return '';
    final host = Uri.tryParse(srsUrl)?.host;
    return 'SRS: ${host?.isNotEmpty == true ? host : srsUrl}';
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'kind': kind.name,
        if (srsUrl.isNotEmpty) 'srsUrl': srsUrl,
        if (ports.isNotEmpty) 'ports': ports,
        if (portRanges.isNotEmpty) 'portRanges': portRanges,
        if (packages.isNotEmpty) 'packages': packages,
        if (protocols.isNotEmpty) 'protocols': protocols,
        if (ipIsPrivate) 'ipIsPrivate': true,
        'outbound': outbound,
      };

  factory CustomRuleSrs.fromJson(Map<String, dynamic> j) => CustomRuleSrs(
        id: _id(j),
        name: (j['name'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        srsUrl: (j['srsUrl'] as String?) ?? '',
        ports: _stringList(j['ports']),
        portRanges: _stringList(j['portRanges']),
        packages: _stringList(j['packages']),
        protocols: _stringList(j['protocols']),
        ipIsPrivate: (j['ipIsPrivate'] as bool?) ?? false,
        outbound: _outbound(j),
      );

  CustomRuleSrs copyWith({
    String? name,
    bool? enabled,
    String? srsUrl,
    List<String>? ports,
    List<String>? portRanges,
    List<String>? packages,
    List<String>? protocols,
    bool? ipIsPrivate,
    String? outbound,
  }) =>
      CustomRuleSrs(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        srsUrl: srsUrl ?? this.srsUrl,
        ports: ports ?? this.ports,
        portRanges: portRanges ?? this.portRanges,
        packages: packages ?? this.packages,
        protocols: protocols ?? this.protocols,
        ipIsPrivate: ipIsPrivate ?? this.ipIsPrivate,
        outbound: outbound ?? this.outbound,
      );

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
    required this.presetId,
    Map<String, String>? varsValues,
  }) : varsValues = Map<String, String>.from(varsValues ?? const {});

  String presetId;

  /// Значения переменных пресета, выставленные юзером в UI.
  ///
  /// Семантика (spec §033 expansion):
  /// - ключ **отсутствует** → юзер не трогал контрол → применяется
  ///   `default_value` из шаблона.
  /// - ключ **есть, значение непустое** → явный выбор.
  /// - ключ **есть, значение пустое** → explicit "— (none)" для optional var;
  ///   фрагменты с unresolved `@name` выкидываются.
  Map<String, String> varsValues;

  @override
  CustomRuleKind get kind => CustomRuleKind.preset;

  @override
  String get summary {
    if (presetId.isEmpty) return '';
    final parts = <String>['preset: $presetId'];
    if (varsValues.isNotEmpty) {
      final shown = varsValues.entries
          .where((e) => e.value.isNotEmpty)
          .map((e) => '${e.key}=${e.value}')
          .take(2)
          .join(', ');
      if (shown.isNotEmpty) parts.add(shown);
    }
    return parts.join(' · ');
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'kind': kind.name,
        'presetId': presetId,
        if (varsValues.isNotEmpty) 'varsValues': varsValues,
      };

  factory CustomRulePreset.fromJson(Map<String, dynamic> j) => CustomRulePreset(
        id: _id(j),
        name: (j['name'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        presetId: (j['presetId'] as String?) ?? '',
        varsValues: _stringMap(j['varsValues']),
      );

  CustomRulePreset copyWith({
    String? name,
    bool? enabled,
    String? presetId,
    Map<String, String>? varsValues,
  }) =>
      CustomRulePreset(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        presetId: presetId ?? this.presetId,
        varsValues: varsValues ?? this.varsValues,
      );

  @override
  CustomRulePreset withEnabled(bool enabled) => copyWith(enabled: enabled);
  @override
  CustomRulePreset withName(String name) => copyWith(name: name);

  /// Для preset outbound хранится в `varsValues['outbound']`. Применяется
  /// в `preset_expand` как **universal override**: полностью заменяет
  /// template-решение независимо от того, задан в шаблоне `@outbound`,
  /// hardcoded `outbound: "<tag>"` или shorthand `action: "reject"`.
  /// Юзер может переключить Block Ads с reject на vpn-1, и наоборот любой
  /// канал на reject. См. spec §033 Expansion §5 "Universal outbound override".
  @override
  CustomRulePreset withOutbound(String outbound) {
    final updated = Map<String, String>.from(varsValues);
    updated['outbound'] = outbound;
    return copyWith(varsValues: updated);
  }
}

// ─── helpers ───────────────────────────────────────────────────────────

String? _id(Map<String, dynamic> j) {
  final id = j['id'] as String?;
  return (id?.trim().isNotEmpty ?? false) ? id : null;
}

/// Читает `outbound`, fallback на legacy-поле `target` (до 1.4.1 rename).
String _outbound(Map<String, dynamic> j) =>
    (j['outbound'] as String?) ?? (j['target'] as String?) ?? 'direct-out';

List<String> _stringList(dynamic v) {
  if (v is! List) return const [];
  return v.map((e) => e.toString()).toList();
}

Map<String, String> _stringMap(dynamic v) {
  if (v is! Map) return const {};
  return {
    for (final e in v.entries)
      if (e.key is String) e.key as String: e.value?.toString() ?? '',
  };
}
