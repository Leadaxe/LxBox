import '../services/parser/uri_utils.dart' show newUuidV4;

/// Разновидность `CustomRule` — inline headless rule vs remote `.srs` rule_set.
///
/// - `inline` — внутри правила напрямую хранятся поля домен/IP/порт/package,
///   emit'ятся как headless rule с OR-семантикой внутри категории, AND
///   между категориями.
/// - `srs` — binary `.srs` rule_set, скачивается вручную через UI в локальный
///   кэш (`$docs/rule_sets/<id>.srs`); в sing-box-конфиг попадает как
///   `type: local`, URL в рантайм не дергается. Port, protocol и packages
///   применяются на уровне routing rule (AND).
enum CustomRuleKind { inline, srs }

/// Sentinel-значение для `CustomRule.target`, которое `applyCustomRules`
/// матчит на `{action: "reject"}` вместо `{outbound: <tag>}`. sing-box не
/// имеет outbound'а с таким именем — коллизий нет.
const String kRejectTarget = 'reject';

/// Known L7 protocols для sing-box rule `protocol` field. Применяется
/// через AND (routing rule level — headless rule не поддерживает protocol).
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

/// Пользовательское правило маршрутизации (spec §030 — Routing).
///
/// Per sing-box default rule matching: внутри одной категории — OR, между
/// категориями — AND. Одно правило с `domainSuffixes=[.ru]`, `ports=[443]`,
/// `packages=[org.mozilla.firefox]` матчится как
/// `(domain_suffix==.ru) && (port==443) && (package_name==…firefox)` —
/// классический кейс "Firefox на .ru домены".
///
/// `protocols` живёт на routing rule level (AND с rule_set match), т.к.
/// sing-box headless rule не поддерживает поле `protocol`.
class CustomRule {
  CustomRule({
    String? id,
    required this.name,
    this.enabled = true,
    this.kind = CustomRuleKind.inline,
    this.domains = const [],
    this.domainSuffixes = const [],
    this.domainKeywords = const [],
    this.ipCidrs = const [],
    this.ports = const [],
    this.portRanges = const [],
    this.packages = const [],
    this.protocols = const [],
    this.ipIsPrivate = false,
    this.srsUrl = '',
    this.target = 'direct-out',
  }) : id = id ?? newUuidV4();

  final String id;
  String name;
  bool enabled;
  CustomRuleKind kind;

  // Inline OR-группа #1 (domain-family + ip).
  List<String> domains;
  List<String> domainSuffixes;
  List<String> domainKeywords;
  List<String> ipCidrs;

  // Inline OR-группа #2 (port-family). AND с domain-family.
  List<String> ports;       // user-input, int-parse'ится на emit
  List<String> portRanges;  // "8000:9000", ":3000", "4000:"

  // Inline OR-группа #3 (package_name). AND с остальными.
  List<String> packages;

  // Routing-rule-level AND.
  List<String> protocols;   // kKnownProtocols subset

  /// Match приватных IP (RFC1918 + loopback + link-local). Принадлежит той
  /// же OR-группе что domain/ip_cidr (см. sing-box default rule matching).
  bool ipIsPrivate;

  // srs-only.
  String srsUrl;

  String target; // outbound tag или kRejectTarget

  /// Ports как int-массив для sing-box (формат `port: [80, 443]`).
  /// Нерасспарсенные/мусорные значения молча отбрасываются.
  List<int> get intPorts => ports
      .map(int.tryParse)
      .whereType<int>()
      .where((p) => p >= 0 && p <= 65535)
      .toList();

  /// Короткая сводка для subtitle в списке правил на RoutingScreen.
  /// Empty → правило пустое (юзеру подсказка "Tap to add match fields").
  String get summary {
    if (kind == CustomRuleKind.srs) {
      if (srsUrl.trim().isEmpty) return '';
      final host = Uri.tryParse(srsUrl)?.host;
      return 'SRS: ${host?.isNotEmpty == true ? host : srsUrl}';
    }
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

  factory CustomRule.fromJson(Map<String, dynamic> j) => CustomRule(
        id: (j['id'] as String?)?.trim().isNotEmpty == true
            ? j['id'] as String
            : null,
        name: (j['name'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        kind: CustomRuleKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => CustomRuleKind.inline,
        ),
        domains: _stringList(j['domains']),
        domainSuffixes: _stringList(j['domainSuffixes']),
        domainKeywords: _stringList(j['domainKeywords']),
        ipCidrs: _stringList(j['ipCidrs']),
        ports: _stringList(j['ports']),
        portRanges: _stringList(j['portRanges']),
        packages: _stringList(j['packages']),
        protocols: _stringList(j['protocols']),
        ipIsPrivate: (j['ipIsPrivate'] as bool?) ?? false,
        srsUrl: (j['srsUrl'] as String?) ?? '',
        target: (j['target'] as String?) ?? 'direct-out',
      );

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
        if (srsUrl.isNotEmpty) 'srsUrl': srsUrl,
        'target': target,
      };

  CustomRule copyWith({
    String? name,
    bool? enabled,
    CustomRuleKind? kind,
    List<String>? domains,
    List<String>? domainSuffixes,
    List<String>? domainKeywords,
    List<String>? ipCidrs,
    List<String>? ports,
    List<String>? portRanges,
    List<String>? packages,
    List<String>? protocols,
    bool? ipIsPrivate,
    String? srsUrl,
    String? target,
  }) =>
      CustomRule(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        kind: kind ?? this.kind,
        domains: domains ?? this.domains,
        domainSuffixes: domainSuffixes ?? this.domainSuffixes,
        domainKeywords: domainKeywords ?? this.domainKeywords,
        ipCidrs: ipCidrs ?? this.ipCidrs,
        ports: ports ?? this.ports,
        portRanges: portRanges ?? this.portRanges,
        packages: packages ?? this.packages,
        protocols: protocols ?? this.protocols,
        ipIsPrivate: ipIsPrivate ?? this.ipIsPrivate,
        srsUrl: srsUrl ?? this.srsUrl,
        target: target ?? this.target,
      );
}

List<String> _stringList(dynamic v) {
  if (v is! List) return const [];
  return v.map((e) => e.toString()).toList();
}
