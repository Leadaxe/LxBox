import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../config/consts.dart' show kDirectOutboundTag;
import '../services/builder/rule_tree_tags.dart' show ruleRefHash;
import '../services/contract/registry.dart' show ContractRegistry;
import '../services/contract/rule_conditions.dart';
import '../services/parser/uri_utils.dart' show newUuidV4;
import '../services/l10n/locale_controller.dart';
import 'rule_tree.dart';

export 'rule_tree.dart' show RuleNode, RuleLeaf, RuleGroup, RuleTreeBody;

/// Sealed-иерархия пользовательских правил маршрутизации (spec §030, v1.4.1
/// task 011). Три варианта с разным шейпом и поведением:
///
/// - [CustomRuleTree] — §757: тело-дерево условий (простые правила и группы
///   `and`/`or`), ссылки на наборы (`refs`) внутри простых правил. Заменило
///   прежние `CustomRuleInline` (свои условия) и `CustomRuleSrs` (наборы по
///   ссылке): вид `inline` | `srs` выводится из дерева. Файлы наборов —
///   локальный кэш (spec §011), sing-box получает `type: local, path`.
/// - [CustomRulePreset] — тонкая ссылка на `SelectableRule` в шаблоне.
///   Bundle-пресет с типизированными vars. Содержимое (rule_set / DNS /
///   routing) разворачивается на каждом `buildConfig`'е — обновил шаблон,
///   новое поведение у всех юзеров (spec §033).
///
/// Хранение — записи `rules[]` контракта 1.0 кодеком
/// `codec/rule_record.dart` (§439). В рантайме предпочтительнее
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

  /// Enum-дискриминатор вида. §757: у [CustomRuleTree] вычисляется по
  /// дереву (`srs` — есть `refs`, иначе `inline`).
  CustomRuleKind get kind;

  /// Короткая сводка для subtitle на RoutingScreen. Пустая → UI покажет
  /// заглушку "Tap to edit". Существительные-счётчики через getLocalText.plural
  /// (рендер по локали в момент показа).
  String summary();

  // ─── Convenience getters — упрощают чтение в UI/builder без pattern-match.
  //
  // §757: плоские геттеры читают КОРЕНЬ дерева, когда он — простой узел
  // ([flatLeaf]); у правила с группами и у прочих видов — пусто. Ответ по
  // всему правилу (все ссылки, «есть доменное условие») — обходы дерева:
  // [allRefs], [hasDomainMatch], [dnsLayerEligible].

  /// §757 — корень дерева, если это простой узел; иначе null.
  RuleLeaf? get flatLeaf => switch (this) {
        CustomRuleTree(:final root) when root is RuleLeaf => root,
        _ => null,
      };

  List<String> _strs(String key) => _leafStrings(flatLeaf, key);
  bool _flag(String key) => flatLeaf?.conditions[key] == true;

  List<String> get domains => _strs(kRuleKeyDomain);
  List<String> get domainSuffixes => _strs(kRuleKeyDomainSuffix);
  List<String> get domainKeywords => _strs(kRuleKeyDomainKeyword);

  /// §712 — `domain_regex`.
  List<String> get domainRegexes => _strs(kRuleKeyDomainRegex);
  List<String> get ipCidrs => _strs(kRuleKeyIpCidr);

  /// Порты строками (в дереве — числа `port`).
  List<String> get ports => _strs(kRuleKeyPort);
  List<String> get portRanges => _strs(kRuleKeyPortRange);
  List<String> get packages => _strs(kRuleKeyPackageName);

  /// §712 — `package_name_regex`.
  List<String> get packageRegexes => _strs(kRuleKeyPackageNameRegex);
  List<String> get protocols => _strs(kRuleKeyProtocol);

  /// §240 — L4-транспорт (`network`: tcp/udp/icmp).
  List<String> get network => _strs(kRuleKeyNetwork);
  bool get ipIsPrivate => _flag(kRuleKeyIpIsPrivate);

  /// §030/new_fields — source-IP-CIDR (источник пакета).
  List<String> get sourceIpCidrs => _strs(kRuleKeySourceIpCidr);

  /// §030/new_fields — `source_ip_is_private`.
  bool get sourceIpIsPrivate => _flag(kRuleKeySourceIpIsPrivate);

  /// §030/new_fields — `inbound`-ось: теги inbound'ов билдера (`tun-in`/
  /// `mixed-in`, §119; `sysproxy-in` — системный HTTP-прокси, §629).
  List<String> get inbounds => _strs(kRuleKeyInbound);

  /// §051 — список SSID'ов для условия `wifi_ssid`. Чтение текущего ssid
  /// требует `NEARBY_WIFI_DEVICES + ACCESS_BACKGROUND_LOCATION` permission на
  /// API 33+ (см. §050 findings).
  List<String> get wifiSsids => _strs(kRuleKeyWifiSsid);

  /// §051 — список BSSID'ов (`xx:xx:xx:xx:xx:xx` lower-case).
  List<String> get wifiBssids => _strs(kRuleKeyWifiBssid);

  /// §694 — тип текущей сети по умолчанию, условие ядра `network_type`.
  List<String> get networkTypes => _strs(kRuleKeyNetworkType);

  /// §694 — только лимитная сеть (`network_is_expensive: true`).
  bool get networkIsExpensive => _flag(kRuleKeyNetworkIsExpensive);

  /// §117 задача 3 — DNS-опция правила (ортогональное поле, только
  /// inline/srs; у preset DNS-аспект живёт в `dns_options.rules` §033).
  /// `null` = выкл (backward-compat: старые записи без `dns`).
  RuleDns? get dns => switch (this) {
        CustomRuleTree(:final dns) => dns,
        _ => null,
      };

  /// §117: правило DNS-mirror-**способно** — включено, сервер выбран, есть
  /// условие, видимое DNS-слою. НЕ зависит от `dns.enabled` — строка
  /// mirror-группы видна и при выключенном DNS-аспекте (switch off, серая).
  bool get dnsMirrorEligible =>
      enabled && (dns?.serverTag.isNotEmpty ?? false) && dnsLayerEligible;

  /// §757 (§6.11): DNS-зеркало правила непусто — в дереве есть условие,
  /// которое DNS-слой может проверить (ключ `dns: true` таблицы условий,
  /// `refs`, рукописный `rule_set`, inline-набор с доменным ключом). Особый
  /// случай `ip_cidr + inbound` снят: лист `{ip_cidr, inbound}` даёт
  /// зеркало по `inbound` (кейс корпуса `ip_cidr_inbound_mirror`).
  bool get dnsLayerEligible => switch (this) {
        CustomRuleTree(:final root) =>
          ruleTreeMirrorNonEmpty(root, ruleConditionTable),
        _ => false,
      };

  /// §757: DNS-опция включена, а зеркало пустое — опция не действует
  /// (⚠ «DNS options have no effect…» в окне правила и в строке списка).
  bool get dnsOptionsWithoutEffect {
    final d = dns;
    if (d == null) return false;
    final on = (d.enabled && d.serverTag.isNotEmpty) ||
        d.forceIpv4 ||
        d.blockHttps ||
        d.fixedMode;
    return on && !dnsLayerEligible;
  }

  /// §117: DNS-mirror **активен** — [dnsMirrorEligible] И галка DNS включена.
  bool get dnsMirrorActive =>
      dnsMirrorEligible &&
      (dns?.enabled ?? false) &&
      !(dns?.fixedMode ?? false);

  /// §256: Force IPv4 (AAAA-глушилка) **применима** — правило DNS-mirror-
  /// способно, но БЕЗ требования `serverTag`: глушилка `predefined` отвечает
  /// локально, серверу не нужна.
  bool get forceIpv4Eligible => enabled && dnsLayerEligible; // §692

  /// §256: Force IPv4 **активна** — [forceIpv4Eligible] И галка включена.
  bool get forceIpv4Active =>
      forceIpv4Eligible &&
      (dns?.forceIpv4 ?? false) &&
      !(dns?.fixedMode ?? false);

  /// §755 / §757: у правила есть условие по домену — `refs` или доменный
  /// ключ (группа `domain` таблицы) хоть в одном простом узле дерева.
  bool get hasDomainMatch => switch (this) {
        CustomRuleTree(:final root) =>
          ruleTreeHasRefsOrDomain(root, ruleConditionTable),
        _ => false,
      };

  /// §755: Block HTTPS/SVCB records **активна** — правило включено, галка
  /// стоит и есть условие по домену.
  bool get blockHttpsActive =>
      enabled && (dns?.blockHttps ?? false) && hasDomainMatch;

  /// §683: Answer = Fixed IP **активен** — тот же гейт, что у
  /// [forceIpv4Eligible], и [RuleDns.fixedMode].
  bool get dnsFixedActive => forceIpv4Eligible && (dns?.fixedMode ?? false);

  /// §247 — resolve-опция правила (только inline/srs). `null` = обычный
  /// outbound (backward-compat: старые записи без `resolve`).
  RuleResolve? get resolve => switch (this) {
        CustomRuleTree(:final resolve) => resolve,
        _ => null,
      };

  /// §247 / §757: правило resolve-**способно** — `refs` или доменный ключ
  /// хоть в одном простом узле дерева.
  bool get resolveEligible => hasDomainMatch;

  /// §247: resolve **активен** — опция задана И правило resolve-способно.
  bool get resolveActive => resolve != null && resolveEligible;

  /// Первая ссылка корня (простого узла); пусто — нет.
  String get srsUrl {
    final urls = srsUrls;
    return urls.isEmpty ? '' : urls.first;
  }

  /// ## 12 / §757 — ссылки наборов КОРНЯ (простого узла) по порядку. Все
  /// ссылки дерева — [allRefs].
  List<String> get srsUrls => flatLeaf?.refs ?? const [];

  /// §757 — значения ключа [key] во всех простых узлах дерева по порядку
  /// (у правила с группами — условия всех под-правил).
  List<String> conditionValues(String key) => switch (this) {
        CustomRuleTree(:final root) => [
            for (final (_, l) in ruleTreeLeaves(root)) ..._leafStrings(l, key),
          ],
        _ => const [],
      };

  /// §757 — все ссылки наборов дерева pre-order без повторов: скачивание,
  /// кэш, автообновление.
  List<String> get allRefs => switch (this) {
        CustomRuleTree(:final root) => ruleTreeRefs(root),
        _ => const [],
      };

  /// §757 (спека §6) — id файла кэша каждого набора по порядку [allRefs]:
  /// `<id правила>~<h8 ссылки>`.
  List<String> get cacheIds =>
      [for (final r in allRefs) CustomRuleTree.cacheIdFor(id, r)];

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
        CustomRuleTree(:final outbound) => outbound,
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

  CustomRule withEnabled(bool enabled);
  CustomRule withName(String name);

  /// Устанавливает outbound. Для `preset` пишет в `varsValues['outbound']`,
  /// для inline/srs — в поле `outbound`.
  CustomRule withOutbound(String outbound);
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
    this.blockHttps = false,
    this.fixedIps = const [],
  });

  final bool enabled;
  final String serverTag;

  /// §256 — Force IPv4: гасить AAAA (IPv6) для матча правила пустым
  /// authoritative-ответом (`ip_version: 6, action: predefined, rcode:
  /// NOERROR`), приложение чисто берёт A. Ортогонально [enabled]/[serverTag]
  /// — глушилка отвечает локально, DNS-серверу не нужна.
  final bool forceIpv4;

  /// §755 — Block HTTPS/SVCB records: отвечать пусто на HTTPS/SVCB-запросы
  /// (RFC 9460) для матча правила (`query_type: [HTTPS, SVCB], action:
  /// predefined, rcode: NOERROR`). Приложение не получает ECH-конфиг и шлёт
  /// открытый SNI — правило по домену видит имя сайта. Ортогонально
  /// [enabled]/[serverTag], как [forceIpv4].
  final bool blockHttps;

  /// §683 — Answer = Fixed IP: правило отвечает на DNS-запросы своего матча
  /// этими адресами (`predefined`, как hosts; IPv4/IPv6, по строке на адрес
  /// в UI). Отдельного флага нет (решение владельца 24.10): режим = в списке
  /// хотя бы один разбираемый адрес ([fixedMode]).
  final List<String> fixedIps;

  /// §683 — режим Answer = Fixed IP. Приоритетнее [enabled] (Dedicated).
  bool get fixedMode => fixedIps.any((ip) => ipRecordType(ip) != null);

  /// §683 — тип DNS-записи для адреса ответа: `A` (IPv4), `AAAA` (IPv6),
  /// null — не адрес. Без `dart:io` (билдер чистый Dart).
  static String? ipRecordType(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (s.contains(':')) {
      try {
        Uri.parseIPv6Address(s);
        return 'AAAA';
      } on FormatException {
        return null;
      }
    }
    try {
      Uri.parseIPv4Address(s);
      return 'A';
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'serverTag': serverTag,
        if (forceIpv4) 'forceIpv4': true,
        if (blockHttps) 'blockHttps': true,
        if (fixedIps.isNotEmpty) 'fixedIps': List<String>.of(fixedIps),
      };

  /// Backward-compat: не-Map (отсутствует в старых записях) → null.
  static RuleDns? fromJson(dynamic j) {
    if (j is! Map) return null;
    final ips = j['fixedIps'];
    return RuleDns(
      enabled: j['enabled'] == true,
      serverTag: j['serverTag']?.toString() ?? '',
      forceIpv4: j['forceIpv4'] == true,
      blockHttps: j['blockHttps'] == true,
      // Ключ `fixed` старых записей игнорируется (сборки с ним не выпускались).
      fixedIps: ips is List
          ? [
              for (final e in ips)
                if (e != null && e.toString().trim().isNotEmpty)
                  e.toString().trim(),
            ]
          : const [],
    );
  }

  RuleDns copyWith({
    bool? enabled,
    String? serverTag,
    bool? forceIpv4,
    bool? blockHttps,
    List<String>? fixedIps,
  }) =>
      RuleDns(
        enabled: enabled ?? this.enabled,
        serverTag: serverTag ?? this.serverTag,
        forceIpv4: forceIpv4 ?? this.forceIpv4,
        blockHttps: blockHttps ?? this.blockHttps,
        fixedIps: fixedIps ?? this.fixedIps,
      );

  /// Ничего не задано — запись `dns` можно снять с правила.
  bool get isEmpty =>
      !enabled &&
      serverTag.isEmpty &&
      !forceIpv4 &&
      !blockHttps &&
      fixedIps.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RuleDns &&
          enabled == other.enabled &&
          serverTag == other.serverTag &&
          forceIpv4 == other.forceIpv4 &&
          blockHttps == other.blockHttps &&
          _listEq(fixedIps, other.fixedIps));

  @override
  int get hashCode =>
      Object.hash(enabled, serverTag, forceIpv4, blockHttps,
          Object.hashAll(fixedIps));
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RuleResolve &&
          only == other.only &&
          strategy == other.strategy &&
          serverTag == other.serverTag &&
          disableCache == other.disableCache &&
          disableOptimisticCache == other.disableOptimisticCache &&
          rewriteTtl == other.rewriteTtl &&
          timeout == other.timeout &&
          clientSubnet == other.clientSubnet);

  @override
  int get hashCode => Object.hash(only, strategy, serverTag, disableCache,
      disableOptimisticCache, rewriteTtl, timeout, clientSubnet);
}

/// Sentinel-значение для `CustomRuleTree.outbound`.
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


// ─── Tree (§757) ───────────────────────────────────────────────────────

/// §757 — ключи условий, которые форма LxBox держит типизированными полями
/// (плоские геттеры [CustomRule], фабрика [CustomRuleTree.flat]). Это
/// представление формы, не источник истины для сборки: какие ключи —
/// условия и куда они идут, решает таблица условий реестра
/// (`registry/rule_conditions.json`). Соответствие полей ключам таблицы
/// сверяет тест.
const kRuleKeyDomain = 'domain';
const kRuleKeyDomainSuffix = 'domain_suffix';
const kRuleKeyDomainKeyword = 'domain_keyword';
const kRuleKeyDomainRegex = 'domain_regex';
const kRuleKeyIpCidr = 'ip_cidr';
const kRuleKeyPort = 'port';
const kRuleKeyPortRange = 'port_range';
const kRuleKeyPackageName = 'package_name';
const kRuleKeyPackageNameRegex = 'package_name_regex';
const kRuleKeyProtocol = 'protocol';
const kRuleKeyNetwork = 'network';
const kRuleKeyIpIsPrivate = 'ip_is_private';
const kRuleKeySourceIpCidr = 'source_ip_cidr';
const kRuleKeySourceIpIsPrivate = 'source_ip_is_private';
const kRuleKeyInbound = 'inbound';
const kRuleKeyWifiSsid = 'wifi_ssid';
const kRuleKeyWifiBssid = 'wifi_bssid';
const kRuleKeyNetworkType = 'network_type';
const kRuleKeyNetworkIsExpensive = 'network_is_expensive';

/// §757 — все ключи типизированных полей формы (порядок — порядок записи
/// плоского правила, как у кодека до §757).
const List<String> kRuleFormFieldKeys = [
  kRuleKeyDomain,
  kRuleKeyDomainSuffix,
  kRuleKeyDomainKeyword,
  kRuleKeyDomainRegex,
  kRuleKeyIpCidr,
  kRuleKeyPort,
  kRuleKeyPortRange,
  kRuleKeyPackageName,
  kRuleKeyPackageNameRegex,
  kRuleKeyProtocol,
  kRuleKeyNetwork,
  kRuleKeyIpIsPrivate,
  kRuleKeySourceIpCidr,
  kRuleKeySourceIpIsPrivate,
  kRuleKeyInbound,
  kRuleKeyWifiSsid,
  kRuleKeyWifiBssid,
  kRuleKeyNetworkType,
  kRuleKeyNetworkIsExpensive,
];

/// §757 — таблица условий правила маршрута. Берётся из реестра контракта;
/// последняя прочитанная копия переживает сброс реестра (тестовый
/// `resetForTesting`). Реестр не загружен ни разу — [StateError]: читать
/// записи правил без таблицы нельзя (тело-дерево не разобрать), а молча
/// уронить правила в хранилище — хуже.
RuleConditionTable get ruleConditionTable {
  final t = ContractRegistry.I.ruleConditions;
  if (t != null) return _keptRuleConditionTable = t;
  final kept = _keptRuleConditionTable;
  if (kept != null) return kept;
  throw StateError('§757: rule condition table is not loaded '
      '(contract registry, registry/rule_conditions.json)');
}

RuleConditionTable? _keptRuleConditionTable;

/// §757 — таблица для тестов без загрузки реестра
/// (`test/flutter_test_config.dart`).
@visibleForTesting
void debugSetRuleConditionTable(RuleConditionTable table) =>
    _keptRuleConditionTable = table;

/// §757 (§6.11) — зеркало дерева непусто (тот же ответ, что
/// `ruleTreeMirrorMatcher(...) != null` сборки со `sideInlineSets`, без
/// тегов): простой узел даёт зеркалу `refs`, рукописный `rule_set`, доменный
/// ключ (inline-набор с ним остаётся в зеркале) или ключ `dns: true`, не
/// уходящий в набор; `and` / `or` непусты, если непуст хоть один ребёнок.
bool ruleTreeMirrorNonEmpty(RuleNode root, RuleConditionTable table) {
  for (final (_, leaf) in ruleTreeLeaves(root)) {
    if (leaf.refs.isNotEmpty || leaf.ruleSet.isNotEmpty) return true;
    for (final k in leaf.conditions.keys) {
      final d = table.key(k);
      if (d == null) continue;
      if (d.isDomain || (d.dns && !d.set)) return true;
    }
  }
  return false;
}

/// §757 — правило маршрута пользователя: тело-дерево условий ([root]) и цель
/// корня. Заменило `CustomRuleInline` и `CustomRuleSrs`: вид (`inline` |
/// `srs`) выводится из дерева ([kind]), ссылки наборов (`refs`) живут в
/// простых узлах. Цель, [dns], [resolve], [updateIntervalHours] — на правиле,
/// одни на всё дерево (TASKS_LXBOX §182 п. 1.2).
///
/// Плоское правило формы — корень-простой узел ([CustomRuleTree.flat],
/// плоские геттеры [CustomRule]).
class CustomRuleTree extends CustomRule {
  CustomRuleTree({
    super.id,
    required super.name,
    super.enabled = true,
    super.orderNum,
    this.root = const RuleLeaf(),
    this.outbound = kDirectOutboundTag,
    this.dns,
    this.resolve,
    this.updateIntervalHours = kDefaultSrsTtlHours,
  });

  /// §757 — плоское правило (корень — один простой узел) из полей формы:
  /// те же именованные параметры, что у прежних `CustomRuleInline` /
  /// `CustomRuleSrs`. [srsUrls] главнее [srsUrl] (## 12); пустые и повторы
  /// ссылок отбрасываются. [extraConditions] — ключи таблицы, которых в
  /// форме нет (`process_*`, `source_port*`): провозятся как есть.
  factory CustomRuleTree.flat({
    String? id,
    required String name,
    bool enabled = true,
    int? orderNum,
    List<String> domains = const [],
    List<String> domainSuffixes = const [],
    List<String> domainKeywords = const [],
    List<String> domainRegexes = const [],
    List<String> ipCidrs = const [],
    List<String> ports = const [],
    List<String> portRanges = const [],
    List<String> packages = const [],
    List<String> packageRegexes = const [],
    List<String> protocols = const [],
    List<String> network = const [],
    bool ipIsPrivate = false,
    List<String> sourceIpCidrs = const [],
    bool sourceIpIsPrivate = false,
    List<String> inbounds = const [],
    List<String> wifiSsids = const [],
    List<String> wifiBssids = const [],
    List<String> networkTypes = const [],
    bool networkIsExpensive = false,
    String srsUrl = '',
    List<String> srsUrls = const [],
    Map<String, Object> extraConditions = const {},
    bool invert = false,
    List<String> ruleSet = const [],
    String outbound = kDirectOutboundTag,
    RuleDns? dns,
    RuleResolve? resolve,
    int updateIntervalHours = kDefaultSrsTtlHours,
  }) {
    final c = <String, Object>{};
    _putFlat(c, kRuleKeyDomain, domains);
    _putFlat(c, kRuleKeyDomainSuffix, domainSuffixes);
    _putFlat(c, kRuleKeyDomainKeyword, domainKeywords);
    _putFlat(c, kRuleKeyDomainRegex, domainRegexes);
    _putFlat(c, kRuleKeyIpCidr, ipCidrs);
    _putFlat(c, kRuleKeyPort, ports);
    _putFlat(c, kRuleKeyPortRange, portRanges);
    _putFlat(c, kRuleKeyPackageName, packages);
    _putFlat(c, kRuleKeyPackageNameRegex, packageRegexes);
    _putFlat(c, kRuleKeyProtocol, protocols);
    _putFlat(c, kRuleKeyNetwork, network);
    _putFlat(c, kRuleKeyIpIsPrivate, ipIsPrivate);
    _putFlat(c, kRuleKeySourceIpCidr, sourceIpCidrs);
    _putFlat(c, kRuleKeySourceIpIsPrivate, sourceIpIsPrivate);
    _putFlat(c, kRuleKeyInbound, inbounds);
    _putFlat(c, kRuleKeyWifiSsid, wifiSsids);
    _putFlat(c, kRuleKeyWifiBssid, wifiBssids);
    _putFlat(c, kRuleKeyNetworkType, networkTypes);
    _putFlat(c, kRuleKeyNetworkIsExpensive, networkIsExpensive);
    for (final e in extraConditions.entries) {
      c.putIfAbsent(e.key, () => e.value);
    }
    return CustomRuleTree(
      id: id,
      name: name,
      enabled: enabled,
      orderNum: orderNum,
      root: RuleLeaf(
        conditions: Map.unmodifiable(c),
        refs: List.unmodifiable(normalizeSrsUrls(srsUrl, srsUrls)),
        ruleSet: List.unmodifiable(ruleSet),
        invert: invert,
      ),
      outbound: outbound,
      dns: dns,
      resolve: resolve,
      updateIntervalHours: updateIntervalHours,
    );
  }

  /// Тело-дерево без цели.
  final RuleNode root;

  /// Outbound-тег либо `kOutboundReject` (→ action: reject).
  @override
  final String outbound;

  /// §117 задача 3 — DNS-опция (зеркало DNS-правила на выбранный сервер).
  @override
  final RuleDns? dns;

  /// §247 — resolve-опция (route action `resolve` перед/вместо route).
  @override
  final RuleResolve? resolve;

  /// §366 / §757 — через сколько часов кэш наборов правила считается
  /// протухшим (все наборы дерева). `0` = не обновлять автоматически.
  final int updateIntervalHours;

  /// §757 (спека §6) — id файла кэша набора по ссылке: `<id>~<h8>`. `~` не
  /// встречается в uuid, коллизий с preset-ключами (`preset__…`) нет.
  static String cacheIdFor(String ruleId, String ref) =>
      '$ruleId~${ruleRefHash(ref)}';

  /// §757 — тело-дерево с целью корня (форма записи `rules[].body`).
  RuleTreeBody get body => RuleTreeBody(root: root, target: targetJson);

  /// Цель корня в форме тела: `action: reject` либо `outbound` (пустая
  /// тоже пишется: сборка такое правило пропускает).
  Map<String, dynamic> get targetJson => outbound == kOutboundReject
      ? const {'action': 'reject'}
      : {'outbound': outbound};

  /// §757 — у дерева больше одного узла (группы): существующая форма такое
  /// правило полями не редактирует.
  bool get hasGroups => root is RuleGroup;

  @override
  CustomRuleKind get kind =>
      ruleTreeRefs(root).isEmpty ? CustomRuleKind.inline : CustomRuleKind.srs;

  @override
  String summary() {
    final root = this.root;
    if (root is RuleLeaf) {
      if (root.refs.isNotEmpty) return _refsSummary(root.refs);
      return _conditionsSummary([root]);
    }
    // §757 — правило с группами: сводка по всем простым узлам дерева.
    final leaves = [for (final (_, l) in ruleTreeLeaves(root)) l];
    final refs = ruleTreeRefs(root);
    return [
      if (refs.isNotEmpty) _refsSummary(refs),
      _conditionsSummary(leaves),
    ].where((p) => p.isNotEmpty).join(' · ');
  }

  static String _refsSummary(List<String> refs) {
    final first = refs.first;
    if (first.trim().isEmpty) return '';
    final host = Uri.tryParse(first)?.host;
    final shown = host?.isNotEmpty == true ? host! : first;
    // ## 12 — несколько наборов: хост первого и число остальных.
    if (refs.length > 1) {
      return getLocalText.s("SRS: %s (+%d)", shown, refs.length - 1);
    }
    return getLocalText.s("SRS: %s", shown);
  }

  static String _conditionsSummary(List<RuleLeaf> leaves) {
    int count(String key) {
      var n = 0;
      for (final l in leaves) {
        n += _leafStrings(l, key).length;
      }
      return n;
    }

    bool flag(String key) => leaves.any((l) => l.conditions[key] == true);
    final parts = <String>[];
    // Ключи словаря — литералами в вызове `getLocalText.plural`: по ним
    // ui_check находит использование строки.
    void add(int n, String text) {
      if (n > 0) parts.add(text);
    }

    add(count(kRuleKeyDomain), getLocalText.plural("%d domains", count(kRuleKeyDomain)));
    add(count(kRuleKeyDomainSuffix), getLocalText.plural("%d suffixes", count(kRuleKeyDomainSuffix)));
    add(count(kRuleKeyDomainKeyword), getLocalText.plural("%d keywords", count(kRuleKeyDomainKeyword)));
    add(count(kRuleKeyDomainRegex), getLocalText.plural("%d domain regex", count(kRuleKeyDomainRegex)));
    add(count(kRuleKeyIpCidr), getLocalText.plural("%d cidrs", count(kRuleKeyIpCidr)));
    if (flag(kRuleKeyIpIsPrivate)) parts.add(getLocalText.s("private ip"));
    add(count(kRuleKeySourceIpCidr), getLocalText.plural("%d src", count(kRuleKeySourceIpCidr)));
    if (flag(kRuleKeySourceIpIsPrivate)) {
      parts.add(getLocalText.s("private src"));
    }
    final totalPorts = count(kRuleKeyPort) + count(kRuleKeyPortRange);
    if (totalPorts > 0) parts.add(getLocalText.plural("%d ports", totalPorts));
    add(count(kRuleKeyPackageName), getLocalText.plural("%d apps", count(kRuleKeyPackageName)));
    add(count(kRuleKeyPackageNameRegex), getLocalText.plural("%d package regex", count(kRuleKeyPackageNameRegex)));
    add(count(kRuleKeyProtocol), getLocalText.plural("%d proto", count(kRuleKeyProtocol)));
    add(count(kRuleKeyNetwork), getLocalText.plural("%d net", count(kRuleKeyNetwork)));
    final inbounds = count(kRuleKeyInbound);
    if (inbounds > 0) parts.add(getLocalText.s("%d in", inbounds));
    final wifi = count(kRuleKeyWifiSsid);
    if (wifi > 0) parts.add(getLocalText.s("%d wifi", wifi));
    // §694 — значения ядра (wifi/cellular/…) как есть, это не текст UI.
    final types = [
      for (final l in leaves) ..._leafStrings(l, kRuleKeyNetworkType),
    ];
    if (types.isNotEmpty) parts.add(types.join('/'));
    if (flag(kRuleKeyNetworkIsExpensive)) parts.add(getLocalText.s("metered"));
    // §757 — ключи таблицы вне формы (`process_*`, `source_port*`) — имя
    // ключа ядра как есть, это не текст UI.
    final extra = <String>{
      for (final l in leaves)
        for (final k in l.conditions.keys)
          if (!kRuleFormFieldKeys.contains(k)) k,
    };
    parts.addAll(extra);
    return parts.join(' · ');
  }

  /// Плоские параметры меняют корень-простой узел (остальные его ключи,
  /// `invert`, рукописный `rule_set` сохраняются). У правила с группами
  /// плоский параметр — ошибка вызывающего ([StateError]): условия
  /// под-правил плоскими полями не выражаются.
  CustomRuleTree copyWith({
    String? name,
    bool? enabled,
    int? orderNum,
    RuleNode? root,
    List<String>? domains,
    List<String>? domainSuffixes,
    List<String>? domainKeywords,
    List<String>? domainRegexes,
    List<String>? ipCidrs,
    List<String>? ports,
    List<String>? portRanges,
    List<String>? packages,
    List<String>? packageRegexes,
    List<String>? protocols,
    List<String>? network,
    bool? ipIsPrivate,
    List<String>? sourceIpCidrs,
    bool? sourceIpIsPrivate,
    List<String>? inbounds,
    List<String>? wifiSsids,
    List<String>? wifiBssids,
    List<String>? networkTypes,
    bool? networkIsExpensive,
    String? srsUrl,
    List<String>? srsUrls,
    String? outbound,
    RuleDns? dns,
    // §257: `dns ?? this.dns` не позволяет обнулить — явный флаг (паттерн
    // clearRewriteTtl в RuleResolve.copyWith).
    bool clearDns = false,
    RuleResolve? resolve,
    // `"resolve": null` в PATCH Debug API — тот же приём, что clearDns.
    bool clearResolve = false,
    int? updateIntervalHours,
  }) {
    final flat = <String, Object?>{
      kRuleKeyDomain: domains,
      kRuleKeyDomainSuffix: domainSuffixes,
      kRuleKeyDomainKeyword: domainKeywords,
      kRuleKeyDomainRegex: domainRegexes,
      kRuleKeyIpCidr: ipCidrs,
      kRuleKeyPort: ports,
      kRuleKeyPortRange: portRanges,
      kRuleKeyPackageName: packages,
      kRuleKeyPackageNameRegex: packageRegexes,
      kRuleKeyProtocol: protocols,
      kRuleKeyNetwork: network,
      kRuleKeyIpIsPrivate: ipIsPrivate,
      kRuleKeySourceIpCidr: sourceIpCidrs,
      kRuleKeySourceIpIsPrivate: sourceIpIsPrivate,
      kRuleKeyInbound: inbounds,
      kRuleKeyWifiSsid: wifiSsids,
      kRuleKeyWifiBssid: wifiBssids,
      kRuleKeyNetworkType: networkTypes,
      kRuleKeyNetworkIsExpensive: networkIsExpensive,
    }..removeWhere((_, v) => v == null);
    final refsChanged = srsUrls != null || srsUrl != null;
    var next = root ?? this.root;
    if (flat.isNotEmpty || refsChanged) {
      final leaf = next;
      if (leaf is! RuleLeaf) {
        throw StateError('§757: flat fields on a rule with condition groups');
      }
      final c = Map<String, Object>.of(leaf.conditions);
      for (final e in flat.entries) {
        c.remove(e.key);
        _putFlat(c, e.key, e.value!);
      }
      // Порядок ключей — как у плоской записи (равенство не зависит от него).
      final ordered = <String, Object>{
        for (final k in kRuleFormFieldKeys)
          if (c.containsKey(k)) k: c[k]!,
        for (final e in c.entries)
          if (!kRuleFormFieldKeys.contains(e.key)) e.key: e.value,
      };
      next = leaf.copyWith(
        conditions: Map.unmodifiable(ordered),
        // Список главнее одиночного URL; одиночный заменяет весь список.
        refs: refsChanged
            ? List.unmodifiable(
                normalizeSrsUrls(srsUrl ?? '', srsUrls ?? const []))
            : null,
      );
    }
    return CustomRuleTree(
      id: id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      orderNum: orderNum ?? this.orderNum,
      root: next,
      outbound: outbound ?? this.outbound,
      dns: clearDns ? null : (dns ?? this.dns),
      resolve: clearResolve ? null : (resolve ?? this.resolve),
      updateIntervalHours: updateIntervalHours ?? this.updateIntervalHours,
    );
  }

  /// §366 — TTL из JSON. Отсутствие, мусор и отрицательные значения → дефолт;
  /// `0` (Never) сохраняем как есть, это осознанный выбор юзера.
  static int ttlHoursFrom(Object? v) {
    final n = v is num ? v.toInt() : null;
    if (n == null || n < 0) return kDefaultSrsTtlHours;
    return n;
  }

  /// Дерево сравнивается по содержимому (порядок ключей узла не значим,
  /// порядок значений и детей — значим).
  String get _rootKey => jsonEncode(_canonical(
      ruleTreeBodyToJson(RuleTreeBody(root: root))));

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CustomRuleTree &&
          id == other.id &&
          name == other.name &&
          enabled == other.enabled &&
          orderNum == other.orderNum &&
          outbound == other.outbound &&
          dns == other.dns &&
          resolve == other.resolve &&
          updateIntervalHours == other.updateIntervalHours &&
          _rootKey == other._rootKey);

  @override
  int get hashCode => Object.hash(id, name, enabled, orderNum, outbound, dns,
      resolve, updateIntervalHours, _rootKey);

  @override
  CustomRuleTree withEnabled(bool enabled) => copyWith(enabled: enabled);
  @override
  CustomRuleTree withName(String name) => copyWith(name: name);
  @override
  CustomRuleTree withOutbound(String outbound) => copyWith(outbound: outbound);
}

/// Значение плоского поля → ключ узла: пустой список и `false` не хранятся;
/// порты — числами 0–65535 (нечисловое отбрасывается, как у кодека до §757);
/// BSSID — в нижнем регистре (§051).
void _putFlat(Map<String, Object> c, String key, Object value) {
  if (value is bool) {
    if (value) c[key] = true;
    return;
  }
  if (value is! List) return;
  if (key == kRuleKeyPort) {
    final ports = <int>[
      for (final e in value)
        if (int.tryParse(e.toString().trim()) case final p?
            when p >= 0 && p <= 65535)
          p,
    ];
    if (ports.isNotEmpty) c[key] = List<int>.unmodifiable(ports);
    return;
  }
  final list = [for (final e in value) e.toString()];
  if (list.isEmpty) return;
  c[key] = List<String>.unmodifiable(
      key == kRuleKeyWifiBssid ? _normalizeBssids(list) : list);
}

/// Значение ключа простого узла списком строк (числа — `toString`).
List<String> _leafStrings(RuleLeaf? leaf, String key) {
  final v = leaf?.conditions[key];
  if (v is List) return [for (final e in v) e.toString()];
  return const [];
}

/// Ключи словарей по алфавиту (рекурсивно), списки — как есть.
Object? _canonical(Object? v) => switch (v) {
      final Map m => {
          for (final k in (m.keys.map((k) => k.toString()).toList()..sort()))
            k: _canonical(m[k]),
        },
      final List l => [for (final e in l) _canonical(e)],
      _ => v,
    };


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
    this.updateIntervalHours,
  }) : varsValues = Map<String, String>.from(varsValues ?? const {});

  /// §757 (§180 контракта) — период обновления наборов пресета, часы, из
  /// записи `rules[].update_interval_hours`; `null` — поля нет, действует
  /// период набора из шаблона. `0` — не обновлять.
  final int? updateIntervalHours;

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

  CustomRulePreset copyWith({
    String? name,
    bool? enabled,
    int? orderNum,
    String? presetId,
    Map<String, String>? varsValues,
    int? updateIntervalHours,
  }) =>
      CustomRulePreset(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        orderNum: orderNum ?? this.orderNum,
        presetId: presetId ?? this.presetId,
        varsValues: varsValues ?? this.varsValues,
        updateIntervalHours: updateIntervalHours ?? this.updateIntervalHours,
      );

  /// `varsValues` сравнивается как словарь: порядок ключей не значим.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CustomRulePreset &&
          id == other.id &&
          name == other.name &&
          enabled == other.enabled &&
          orderNum == other.orderNum &&
          presetId == other.presetId &&
          updateIntervalHours == other.updateIntervalHours &&
          _mapEq(varsValues, other.varsValues));

  @override
  int get hashCode => Object.hash(
        id,
        name,
        enabled,
        orderNum,
        presetId,
        updateIntervalHours,
        Object.hashAllUnordered(
            varsValues.entries.map((e) => Object.hash(e.key, e.value))),
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
/// Валидность синтаксиса проверяется в UI (inline) и в билдере (skip+warning
/// на битом JSON, без падения сборки). Dangling `outbound` внутри тела ловит
/// `validateConfig` тем же путём, что и обычные правила.
///
/// §439 — вид модели, не записи: в записи 1.0 это `inline` + `verbatim: true`
/// с телом-объектом (`codec/rule_record.dart`), форматирование текста в
/// состояние не входит. Отсюда равенство по содержимому JSON.
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

  CustomRuleJson copyWith({String? name, bool? enabled, int? orderNum, String? json}) =>
      CustomRuleJson(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        orderNum: orderNum ?? this.orderNum,
        json: json ?? this.json,
      );

  /// [json] сравнивается по содержимому: тексты, которые разбираются в один
  /// и тот же JSON (порядок ключей значим), равны при любых пробелах; текст,
  /// который не разбирается, — посимвольно.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CustomRuleJson &&
          id == other.id &&
          name == other.name &&
          enabled == other.enabled &&
          orderNum == other.orderNum &&
          (json == other.json ||
              (_canonicalJson(json) ?? json) ==
                  (_canonicalJson(other.json) ?? other.json)));

  @override
  int get hashCode =>
      Object.hash(id, name, enabled, orderNum, _canonicalJson(json) ?? json);

  @override
  CustomRuleJson withEnabled(bool enabled) => copyWith(enabled: enabled);
  @override
  CustomRuleJson withName(String name) => copyWith(name: name);

  /// json-правило не имеет outbound-поля (действие внутри тела) — no-op.
  @override
  CustomRuleJson withOutbound(String outbound) => this;
}

// ─── helpers ───────────────────────────────────────────────────────────

/// Компактная запись разобранного JSON-текста; не разбирается — null.
String? _canonicalJson(String text) {
  try {
    return jsonEncode(jsonDecode(text));
  } on FormatException {
    return null;
  }
}

/// ## 12 — нормализация списка `.srs`-наборов: непустой [srsUrls] главнее
/// одиночного [srsUrl]; trim, пустые и повторы (с сохранением порядка) — вон.
List<String> normalizeSrsUrls(String srsUrl, List<String> srsUrls) {
  final out = <String>[];
  for (final u in srsUrls.isEmpty ? [srsUrl] : srsUrls) {
    final t = u.trim();
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }
  return out;
}

/// ## 12 — список наборов из текста поля редактора: по одному URL на строку
/// (любые пробельные разделители), пустые и повторы отбрасываются.
List<String> parseSrsUrlsText(String text) =>
    normalizeSrsUrls('', text.split(RegExp(r'\s+')));

bool _listEq(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _mapEq(Map<String, String> a, Map<String, String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (!b.containsKey(e.key) || b[e.key] != e.value) return false;
  }
  return true;
}

/// §051 — нормализует BSSID к lower-case формату `xx:xx:xx:xx:xx:xx`.
/// Юзер мог ввести uppercase из браузера/`adb shell` — sing-box матчит
/// case-sensitive по строкам. Здесь tolerant'но lower-case'им и trim'аем,
/// строгую regex-валидацию делает Debug API parser (на write-side).
List<String> _normalizeBssids(List<String> bssids) {
  if (bssids.isEmpty) return const [];
  return bssids.map((b) => b.trim().toLowerCase()).toList(growable: false);
}
