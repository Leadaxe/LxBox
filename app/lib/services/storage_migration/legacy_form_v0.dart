/// Замороженные читатели формы хранения 2.23.2 (§439 §2.1, §2.2).
///
/// Тела `ServerList.fromJson` (с подтипами и `FolderMember.fromJson`),
/// `DetourPolicy.fromJson`, `SubscriptionIdentityOverride.fromJson`,
/// `CustomRule.fromJson` (с подтипами), `SourceChain.fromJson`,
/// `DnsServerRef.fromJson` и `DnsRuleRef.fromJson` на момент 2.23.2 — перенос
/// без правок логики. Миграция читает старые данные ровно так, как читала их
/// 2.23.2, и уже потом пишет кодеком записей 1.0: совпадение `config.json` до и
/// после держится на этом переносе, а не на переписанном разборе.
///
/// Модели строятся конструкторами. Подчинённые объекты, форма которых в 1.0
/// не менялась и которые читает кодек записей (`SubscriptionMeta`,
/// `ImportRule`, `NodeSections`, `RuleDns`, `RuleResolve`), читаются своими
/// `fromJson`.
///
/// Старые имена полей живут только здесь и только на чтении. Зовут модуль
/// миграция хранения (`migrate_storage.dart`) и входы старой формы.
library;

import '../../config/consts.dart' show kDirectOutboundTag;
import '../../models/custom_rule.dart';
import '../../models/dns_ref.dart';
import '../../models/import_rule.dart';
import '../../models/node_sections.dart';
import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../../models/source_chain.dart';
import '../../models/subscription_meta.dart';
import '../json_clone.dart' show deepCloneJson;
import '../parser/body_decoder.dart';
import '../parser/parse_all.dart';

// ─── server_lists[] ─────────────────────────────────────────────────────────

/// `ServerList.fromJson` 2.23.2. Бросает на незнакомый `type` и на запись без
/// `id` — как 2.23.2, которая такую запись пропускала.
ServerList readLegacyServerList(Map<String, dynamic> j) {
  final t = j['type'] as String?;
  switch (t) {
    case 'subscription':
      return _readSubscription(j);
    case 'user':
      return _readUserServer(j);
    case 'folder':
      return _readFolder(j);
    default:
      throw FormatException('Unknown ServerList type: $t');
  }
}

/// `SubscriptionServers.fromJson` 2.23.2.
SubscriptionServers _readSubscription(Map<String, dynamic> j) =>
    SubscriptionServers(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? '',
      enabled: (j['enabled'] as bool?) ?? true,
      tagPrefix: (j['tag_prefix'] as String?) ?? '',
      detourPolicy: _readDetourPolicy(
          (j['detour_policy'] as Map?)?.cast<String, dynamic>() ?? const {}),
      url: (j['url'] as String?) ?? '',
      meta: j['meta'] == null
          ? null
          : SubscriptionMeta.fromJson(
              (j['meta'] as Map).cast<String, dynamic>()),
      lastUpdated: (j['last_updated'] as String?) == null
          ? null
          : DateTime.tryParse(j['last_updated'] as String),
      lastUpdateAttempt: (j['last_update_attempt'] as String?) == null
          ? null
          : DateTime.tryParse(j['last_update_attempt'] as String),
      lastUpdateStatus: UpdateStatus.values.firstWhere(
        (s) => s.name == j['last_update_status'],
        orElse: () => UpdateStatus.never,
      ),
      updateIntervalHours: (j['update_interval_hours'] as num?)?.toInt() ?? 24,
      lastNodeCount: (j['last_node_count'] as num?)?.toInt() ?? 0,
      consecutiveFails: (j['consecutive_fails'] as num?)?.toInt() ?? 0,
      disabledHashes: _readDisabledHashes(j['disabled_hashes']),
      identity: j['identity'] == null
          ? null
          : _readIdentity((j['identity'] as Map).cast<String, dynamic>()),
      importRules: _readImportRules(j['import_rules']),
      importRulesEnabled: (j['import_rules_enabled'] as bool?) ?? true,
      onUpdateAction: SubscriptionOnUpdateAction.fromJson(j['on_update_action']),
    );

/// `SubscriptionServers._disabledHashesFromJson` 2.23.2: не-Map → пусто,
/// значение не датой — пропуск отметки.
Map<String, DateTime> _readDisabledHashes(dynamic raw) {
  if (raw is! Map) return const {};
  final out = <String, DateTime>{};
  raw.forEach((k, v) {
    final t = v is String ? DateTime.tryParse(v) : null;
    if (t != null) out[k.toString()] = t;
  });
  return out;
}

/// `SubscriptionServers._importRulesFromJson` 2.23.2.
List<ImportRule> _readImportRules(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((m) => ImportRule.fromJson(m.cast<String, dynamic>()))
      .toList();
}

/// `SubscriptionIdentityOverride.fromJson` 2.23.2.
SubscriptionIdentityOverride _readIdentity(Map<String, dynamic> j) =>
    SubscriptionIdentityOverride(
      userAgent: (j['user_agent'] as String?) ?? '',
      sendHwid: (j['send_hwid'] as bool?) ?? false,
      hwid: (j['hwid'] as String?) ?? '',
      deviceOs: (j['device_os'] as String?) ?? '',
      verOs: (j['ver_os'] as String?) ?? '',
      deviceModel: (j['device_model'] as String?) ?? '',
    );

/// `UserServer.fromJson` 2.23.2: узлы перечитываются из `raw_body`.
UserServer _readUserServer(Map<String, dynamic> j) {
  final rawBody = (j['raw_body'] as String?) ?? '';
  final nodes = <NodeSpec>[];
  if (rawBody.isNotEmpty) {
    try {
      nodes.addAll(parseAll(decode(rawBody)));
    } catch (_) {
      // Некорректный raw — узлов нет, запись остаётся.
    }
  }
  return UserServer(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    enabled: (j['enabled'] as bool?) ?? true,
    tagPrefix: (j['tag_prefix'] as String?) ?? '',
    detourPolicy: _readDetourPolicy(
        (j['detour_policy'] as Map?)?.cast<String, dynamic>() ?? const {}),
    origin: UserSource.values.firstWhere(
      (e) => e.name == j['origin'],
      orElse: () => UserSource.manual,
    ),
    rawBody: rawBody,
    sections: NodeSections.fromJson(j['sections']),
    nodes: nodes,
  );
}

/// `FolderServers.fromJson` 2.23.2.
FolderServers _readFolder(Map<String, dynamic> j) => FolderServers(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? '',
      enabled: (j['enabled'] as bool?) ?? true,
      tagPrefix: (j['tag_prefix'] as String?) ?? '',
      detourPolicy: _readDetourPolicy(
          (j['detour_policy'] as Map?)?.cast<String, dynamic>() ?? const {}),
      createdAt: DateTime.tryParse((j['created_at'] as String?) ?? '') ??
          DateTime.now(),
      members: ((j['members'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => readLegacyFolderMember(m.cast<String, dynamic>()))
          .toList(),
      pingUrl: (j['ping_url'] as String?)?.trim().isNotEmpty == true
          ? (j['ping_url'] as String).trim()
          : null,
      pingTimeoutMs: (j['ping_timeout_ms'] as num?)?.toInt(),
    );

/// `FolderMember.fromJson` 2.23.2.
FolderMember readLegacyFolderMember(Map<String, dynamic> j) => FolderMember(
      raw: (j['raw'] as String?) ?? '',
      enabled: (j['enabled'] as bool?) ?? true,
      detour: (j['detour'] as String?) ?? '',
      sections: NodeSections.fromJson(j['sections']),
    );

/// `DetourPolicy.fromJson` 2.23.2.
DetourPolicy _readDetourPolicy(Map<String, dynamic> j) => DetourPolicy(
      registerDetourServers: (j['register_detour_servers'] as bool?) ?? false,
      registerDetourInAuto: (j['register_detour_in_auto'] as bool?) ?? false,
      useDetourServers: (j['use_detour_servers'] as bool?) ?? true,
      overrideDetour: (j['override_detour'] as String?) ?? '',
      replaceDetourChain: (j['replace_detour_chain'] as bool?) ?? false,
    );

// ─── chains[] ───────────────────────────────────────────────────────────────

/// Цепочка 2.23.2 и её место в общем списке источников.
typedef LegacyChain = ({SourceChain chain, int order});

/// `SourceChain.fromJson` 2.23.2. Позиция `order` возвращается рядом: модель
/// 1.0 её не держит, место цепочки — индекс в `sources[]`.
LegacyChain readLegacyChain(Map<String, dynamic> json) {
  final tag = (json['tag'] as String? ?? '').trim();
  return (
    chain: SourceChain(
      tag: tag,
      label: json['label'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      hops: [
        for (final h in (json['hops'] as List? ?? const []))
          if (h is String) h,
      ],
      idleTimeout: json['idle_timeout'] as String? ?? '',
      stripEvasion:
          json['strip_evasion'] is bool ? json['strip_evasion'] as bool : null,
      strip: {
        for (final key in kChainStripKeys)
          if ((json['strip'] as Map?)?[key] is bool)
            key: (json['strip'] as Map)[key] as bool,
      },
      rewrite:
          (deepCloneJson(json['rewrite']) as Map?)?.cast<String, dynamic>() ??
              const {},
    ),
    order: json['order'] is int ? json['order'] as int : -1,
  );
}

/// `_sortChainsByOrder` 2.23.2: стабильная сортировка по `order`, записи без
/// позиции (-1) — в конец, при равенстве — порядок файла.
List<SourceChain> sortLegacyChains(List<LegacyChain> chains) {
  const unset = 1 << 30;
  final indexed = [
    for (var i = 0; i < chains.length; i++) (c: chains[i], at: i),
  ];
  indexed.sort((a, b) {
    final ao = a.c.order < 0 ? unset : a.c.order;
    final bo = b.c.order < 0 ? unset : b.c.order;
    if (ao != bo) return ao.compareTo(bo);
    return a.at.compareTo(b.at);
  });
  return [for (final e in indexed) e.c.chain];
}

// ─── custom_rules[] ─────────────────────────────────────────────────────────

/// `CustomRule.fromJson` 2.23.2: без `kind` — inline.
CustomRule readLegacyCustomRule(Map<String, dynamic> j) {
  final kindRaw = j['kind'] as String?;
  final kind = CustomRuleKind.values.firstWhere(
    (k) => k.name == kindRaw,
    orElse: () => CustomRuleKind.inline,
  );
  return switch (kind) {
    CustomRuleKind.inline => _readInline(j),
    CustomRuleKind.srs => _readSrs(j),
    CustomRuleKind.preset => _readPreset(j),
    CustomRuleKind.json => _readJson(j),
  };
}

CustomRuleInline _readInline(Map<String, dynamic> j) => CustomRuleInline(
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

CustomRuleSrs _readSrs(Map<String, dynamic> j) => CustomRuleSrs(
      id: _id(j),
      name: (j['name'] as String?) ?? '',
      enabled: (j['enabled'] as bool?) ?? true,
      orderNum: j['num'] as int?,
      srsUrl: (j['srsUrl'] as String?) ?? '',
      srsUrls: _stringList(j['srsUrls']),
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
      updateIntervalHours: _ttlHours(j['updateIntervalHours']),
    );

CustomRulePreset _readPreset(Map<String, dynamic> j) => CustomRulePreset(
      id: _id(j),
      name: (j['name'] as String?) ?? '',
      enabled: (j['enabled'] as bool?) ?? true,
      orderNum: j['num'] as int?,
      presetId: (j['presetId'] as String?) ?? '',
      varsValues: _stringMap(j['varsValues']),
    );

CustomRuleJson _readJson(Map<String, dynamic> j) => CustomRuleJson(
      id: _id(j),
      name: (j['name'] as String?) ?? '',
      enabled: (j['enabled'] as bool?) ?? true,
      orderNum: j['num'] as int?,
      json: (j['json'] as String?) ?? '',
    );

String? _id(Map<String, dynamic> j) {
  final id = j['id'] as String?;
  return (id?.trim().isNotEmpty ?? false) ? id : null;
}

/// `outbound` с запасным `target` (имя до 1.4.1).
String _outbound(Map<String, dynamic> j) =>
    (j['outbound'] as String?) ?? (j['target'] as String?) ?? kDirectOutboundTag;

/// `CustomRuleSrs.ttlHoursFrom` 2.23.2.
int _ttlHours(Object? v) {
  final n = v is num ? v.toInt() : null;
  if (n == null || n < 0) return kDefaultSrsTtlHours;
  return n;
}

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

// ─── dns_options ────────────────────────────────────────────────────────────

/// `DnsServerRef.fromJson` 2.23.2: запись без `kind` (форма до §043),
/// незнакомый вид, пустой `tag`, inline без `body` → null.
DnsServerRef? readLegacyDnsServer(Map<String, dynamic> j) {
  final kind = j['kind'];
  final tag = j['tag']?.toString();
  if (kind is! String || tag == null || tag.isEmpty) return null;
  final enabled = j['enabled'] != false;
  final description = j['description']?.toString();
  switch (kind) {
    case 'inline':
      final body = j['body'];
      if (body is! Map) return null;
      return DnsServerInline(
        enabled: enabled,
        tag: tag,
        body: _copyMap(body),
        description: description,
      );
    case 'preset':
      return DnsServerPreset(
          enabled: enabled, tag: tag, description: description);
    case 'template':
      final vv = j['varValues'];
      return DnsServerTemplate(
        enabled: enabled,
        tag: tag,
        varValues: vv is Map
            ? {
                for (final e in vv.entries)
                  if (e.value != null) e.key.toString(): e.value.toString()
              }
            : const {},
        description: description,
      );
    default:
      return null;
  }
}

/// `DnsRuleRef.fromJson` 2.23.2: незнакомый вид (в том числе `user` и `rule`
/// до §033) или запись без обязательных полей → null.
DnsRuleRef? readLegacyDnsRule(Map<String, dynamic> j) {
  final kind = j['kind'];
  if (kind is! String) return null;
  final enabledByDefault = j['enabled'] != false;
  final enabledExplicit = j['enabled'] == true;
  switch (kind) {
    case 'inline':
      final name = j['name']?.toString();
      final rule = j['rule'];
      if (name == null || name.isEmpty || rule is! Map) return null;
      return DnsRuleInline(
        name: name,
        rule: _copyMap(rule),
        enabled: enabledByDefault,
      );
    case 'srs':
      final id = j['id']?.toString();
      final name = j['name']?.toString();
      if (id == null || id.isEmpty || name == null || name.isEmpty) {
        return null;
      }
      final body = j['body'];
      final server = j['server'];
      final rule = j['rule'];
      final srsUrl = j['srsUrl'];
      return DnsRuleSrs(
        name: name,
        id: id,
        body: body is Map ? _copyMap(body) : null,
        server: server is String ? server : null,
        rule: rule is Map ? _copyMap(rule) : null,
        srsUrl: srsUrl is String ? srsUrl : null,
        enabled: enabledByDefault,
      );
    case 'preset':
      final pid = j['presetId']?.toString();
      if (pid == null || pid.isEmpty) return null;
      return DnsRulePreset(presetId: pid, enabled: enabledExplicit);
    case 'template':
      final name = j['name']?.toString();
      if (name == null || name.isEmpty) return null;
      return DnsRuleTemplate(name: name, enabled: enabledExplicit);
    default:
      return null;
  }
}

Object? _copyJson(Object? v) {
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) e.key.toString(): _copyJson(e.value),
    };
  }
  if (v is List) return [for (final x in v) _copyJson(x)];
  return v;
}

Map<String, dynamic> _copyMap(Map v) => _copyJson(v) as Map<String, dynamic>;
