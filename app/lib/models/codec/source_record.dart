/// Кодек записей `sources[]` контракта 1.0 для подписки, одиночного сервера
/// и папки с членами (§439 §1.2). Цепочка — `chain_record.dart`.
///
/// Запись = поля контракта (К) и рядом поля LxBox (L, ONE_NAMESPACE §1).
/// Кэш и производное не пишутся: `nodes[]` подписки живёт в `sub_cache/`,
/// узлы сервера и члена папки перечитываются из `origin.raw`. Член-группа
/// папки (`kind: auto`) — запись `codec/auto_group_record.dart`.
///
/// Чтение терпимо: форма нормализуется (ссылка строкой, `body` без
/// исходника, не тот тип скаляра), битое не бросает. Незнакомые ключи
/// попадают в [RecordRead.unknownKeys] путями (`fold`, `tag_policy.postfix`,
/// `identity.hash_device_model`); то, что прочитано не дословно (тег записи
/// разошёлся с текстом, отброшенный член папки или запись секции),
/// называется строкой в `notes`. Вызывающий решает, что из этого логировать.
library;

import 'dart:convert';

import '../../services/parser/body_decoder.dart';
import '../../services/parser/parse_all.dart';
import '../../services/node_link_address.dart';
import '../import_rule.dart';
import '../node_link.dart';
import '../node_sections.dart';
import '../node_spec.dart';
import '../record_codec.dart' show RecordRead;
import '../server_list.dart';
import '../subscription_meta.dart';
import 'auto_group_record.dart';
import 'node_link_record.dart';

const String kSourceKindSubscription = 'subscription';
const String kSourceKindServer = 'server';
const String kSourceKindFolder = 'folder';

/// Вид члена папки, чей текст не разобрался в узел.
const String kNodeKindUnsupported = 'unsupported';

/// `reason` неразобранного члена папки (та же строка, что у экспорта 438).
const String kMemberUnparsedReason =
    'the member text does not parse into a node';

// ─── запись ─────────────────────────────────────────────────────────────────

/// Источник LxBox → запись `sources[]`.
Map<String, dynamic> sourceToRecord(ServerList list) => switch (list) {
      SubscriptionServers() => _subscriptionToRecord(list),
      UserServer() => _serverToRecord(list),
      FolderServers() => _folderToRecord(list),
    };

Map<String, dynamic> _subscriptionToRecord(SubscriptionServers s) => {
      'kind': kSourceKindSubscription,
      'id': s.id,
      'name': s.name,
      'enabled': s.enabled,
      'url': s.url,
      if (s.tagPrefix.isNotEmpty) 'tag_policy': _tagPolicyToRecord(s.tagPrefix),
      if (s.identity != null) 'identity': s.identity!.toJson(),
      'update': {'interval_hours': s.updateIntervalHours},
      // §439 п. 10 — unix seconds; доли секунды TTL-очистке не нужны.
      if (s.disabledHashes.isNotEmpty)
        'disabled': {
          for (final e in s.disabledHashes.entries)
            e.key: e.value.millisecondsSinceEpoch ~/ 1000,
        },
      ..._detourLinkToRecord(s.detourPolicy),
      // L — настройки LxBox.
      ..._detourPolicyToRecord(s.detourPolicy),
      if (s.importRules.isNotEmpty)
        'import_rules': [for (final r in s.importRules) r.toJson()],
      if (!s.importRulesEnabled) 'import_rules_enabled': false,
      if (s.onUpdateAction != SubscriptionOnUpdateAction.rebuild)
        'on_update_action': s.onUpdateAction.name,
      // L — рантайм машины.
      if (s.meta != null) 'meta': s.meta!.toJson(),
      if (s.lastUpdated != null)
        'last_updated': s.lastUpdated!.toIso8601String(),
      if (s.lastUpdateAttempt != null)
        'last_update_attempt': s.lastUpdateAttempt!.toIso8601String(),
      if (s.lastUpdateStatus != UpdateStatus.never)
        'last_update_status': s.lastUpdateStatus.name,
      if (s.lastNodeCount != 0) 'last_node_count': s.lastNodeCount,
      if (s.consecutiveFails != 0) 'consecutive_fails': s.consecutiveFails,
    };

/// §439 п. 1–2 — `tag` берётся из разобранного узла (у сервера из нескольких
/// узлов — первого), исходник пишется целиком. `name` (с §243 пуст) и
/// `origin` модели не пишутся.
Map<String, dynamic> _serverToRecord(UserServer u) {
  final tag = _firstNodeTag(u.nodes, u.rawBody);
  return {
    'kind': kSourceKindServer,
    'id': u.id,
    if (tag.isNotEmpty) 'tag': tag,
    'enabled': u.enabled,
    if (u.rawBody.isNotEmpty) 'origin': _originToRecord(u.rawBody),
    ..._detourLinkToRecord(u.detourPolicy),
    if (u.sections != null) 'sections': u.sections!.toJson(),
    // L — настройки LxBox.
    ..._detourPolicyToRecord(u.detourPolicy),
    if (u.tagPrefix.isNotEmpty) 'tag_policy': _tagPolicyToRecord(u.tagPrefix),
  };
}

Map<String, dynamic> _folderToRecord(FolderServers f) => {
      'kind': kSourceKindFolder,
      'id': f.id,
      'name': f.name,
      'enabled': f.enabled,
      if (f.tagPrefix.isNotEmpty) 'tag_policy': _tagPolicyToRecord(f.tagPrefix),
      ..._detourLinkToRecord(f.detourPolicy),
      // L — настройки LxBox.
      ..._detourPolicyToRecord(f.detourPolicy),
      if (f.pingUrl != null) 'ping_url': f.pingUrl,
      if (f.pingTimeoutMs != null) 'ping_timeout_ms': f.pingTimeoutMs,
      // L — момент создания: его отдаёт Debug API `/folders`.
      'created_at': f.createdAt.toIso8601String(),
      'nodes': [for (final m in f.members) _memberToRecord(m, f.id)],
    };

/// Член папки: разобранный — `server` с тегом узла, нет — `unsupported` с
/// причиной, группа — `auto`. Член с пустым текстом тоже пишется: хранение
/// его не теряет.
Map<String, dynamic> _memberToRecord(FolderMember m, String folderId) {
  final node = m.node;
  if (node is AutoSelectSpec) return autoGroupMemberToRecord(m, node, folderId);
  return {
    'kind': node == null ? kNodeKindUnsupported : kSourceKindServer,
    if (node != null && node.tag.isNotEmpty) 'tag': node.tag,
    'enabled': m.enabled,
    if (m.raw.isNotEmpty) 'origin': _originToRecord(m.raw),
    if (m.detour.isNotEmpty) 'detour': nodeLinkToRecord(m.detour),
    if (node == null) 'reason': kMemberUnparsedReason,
    if (m.sections != null) 'sections': m.sections!.toJson(),
  };
}

/// §439 п. 9 — у контракта разделитель внутри префикса, у модели снаружи.
Map<String, dynamic> _tagPolicyToRecord(String prefix) => {'prefix': '$prefix '};

/// Личный detour источника — ссылка записи (§439 п. 8), на любом виде.
Map<String, dynamic> _detourLinkToRecord(DetourPolicy p) => {
      if (p.overrideDetour.isNotEmpty)
        'detour': nodeLinkToRecord(p.overrideDetour),
    };

/// Флаги политики detour без ссылки; при умолчаниях поля нет.
Map<String, dynamic> _detourPolicyToRecord(DetourPolicy p) => {
      if (p.copyWith(overrideDetour: NodeLink.none) != DetourPolicy.defaults)
        'detour_policy': p.toJson(),
    };

/// `origin{kind, raw}`: `kind` выводится из текста (правило экспорта 438:
/// JSON-объект → `json`, WG-INI → `wg_ini`, прочее → `uri`), `raw` — байт в
/// байт.
Map<String, dynamic> _originToRecord(String raw) =>
    {'kind': _originKind(raw), 'raw': raw};

String _originKind(String raw) {
  final t = raw.trim();
  if (t.startsWith('{')) {
    try {
      if (jsonDecode(t) is Map) return 'json';
    } catch (_) {
      // Не JSON — решает общий декодер ниже.
    }
  }
  return decode(t) is IniConfig ? 'wg_ini' : 'uri';
}

String _firstNodeTag(List<NodeSpec> nodes, String raw) {
  final parsed = nodes.isNotEmpty ? nodes : _parseNodes(raw);
  return parsed.isEmpty ? '' : parsed.first.tag;
}

List<NodeSpec> _parseNodes(String raw) {
  if (raw.trim().isEmpty) return const [];
  try {
    return parseAll(decode(raw));
  } catch (_) {
    return const [];
  }
}

// ─── чтение ─────────────────────────────────────────────────────────────────

const Set<String> _subscriptionKeys = {
  'kind', 'id', 'name', 'enabled', 'url', 'tag_policy', 'identity', 'update',
  'disabled', 'detour', 'detour_policy', 'import_rules',
  'import_rules_enabled', 'on_update_action', 'meta', 'last_updated',
  'last_update_attempt', 'last_update_status', 'last_node_count',
  'consecutive_fails',
};

const Set<String> _serverKeys = {
  'kind', 'id', 'tag', 'enabled', 'origin', 'body', 'detour', 'sections',
  'detour_policy', 'tag_policy',
};

const Set<String> _folderKeys = {
  'kind', 'id', 'name', 'enabled', 'tag_policy', 'detour', 'detour_policy',
  'ping_url', 'ping_timeout_ms', 'created_at', 'nodes',
};

const Set<String> _memberKeys = {
  'kind', 'tag', 'enabled', 'origin', 'body', 'detour', 'reason', 'sections',
};

const Set<String> _detourPolicyKeys = {
  'register_detour_servers', 'register_detour_in_auto', 'use_detour_servers',
  'replace_detour_chain',
};

const Set<String> _identityKeys = {
  'user_agent', 'send_hwid', 'hwid', 'device_os', 'ver_os', 'device_model',
};

/// Запись `sources[]` → источник LxBox. Запись цепочки читает
/// `chainFromRecord`; здесь она, как и запись без `id`, — отброс с причиной.
///
/// [sectionDrops] получает отбраковки секций узлов структурно (вид и причина
/// по норме B3, `NodeSections.fromJson`): импорт бэкапа называет их кодом с
/// `reason`, хранению хватает строк в [notes].
///
/// [tolerantLinks] — терпимое чтение ссылок папки (NODE_LINK §7.3): S1
/// (корневая ссылка на члена этой папки → пара) и S3 (пара с финальным тегом
/// группы папки → сырой тег), только при единственном кандидате. Хранение
/// его не включает: писатель хранения пишет пары, а корневая ссылка на
/// тёзку члена законна (узел в корне) и подъём увёл бы её на другой узел.
/// Включают входы чужой формы — импорт файла и Debug API.
RecordRead<ServerList> sourceFromRecord(
  Map<String, dynamic> j, {
  List<String>? notes,
  List<NodeSectionDrop>? sectionDrops,
  bool tolerantLinks = false,
}) {
  final kind = j['kind'];
  if (kind is! String || kind.isEmpty) {
    return const RecordRead.drop('source without kind');
  }
  if (kind != kSourceKindSubscription &&
      kind != kSourceKindServer &&
      kind != kSourceKindFolder) {
    return RecordRead.drop('source kind "$kind" is not read by sourceFromRecord');
  }
  final id = j['id'];
  if (id is! String || id.trim().isEmpty) {
    return RecordRead.drop('source ($kind) without id');
  }
  final unknown = <String>[];
  final ServerList list = switch (kind) {
    kSourceKindSubscription => _subscriptionFromRecord(j, id, notes, unknown),
    kSourceKindServer => _serverFromRecord(j, id, notes, unknown, sectionDrops),
    _ => _folderFromRecord(j, id, notes, unknown, sectionDrops),
  };
  return RecordRead.ok(
    tolerantLinks && list is FolderServers ? liftFolderLinks(list) : list,
    unknownKeys: unknown..sort(),
  );
}

SubscriptionServers _subscriptionFromRecord(
  Map<String, dynamic> j,
  String id,
  List<String>? notes,
  List<String> unknown,
) {
  final where = 'subscription "$id"';
  _collectUnknown(j, _subscriptionKeys, '', unknown);
  final update = j['update'];
  final interval = update is Map ? update['interval_hours'] : null;
  if (update is Map) {
    _collectUnknown(update, const {'interval_hours'}, 'update.', unknown);
  }
  return SubscriptionServers(
    id: id,
    name: _string(j['name']),
    enabled: _bool(j['enabled'], true),
    tagPrefix: _prefixFromRecord(j['tag_policy'], unknown),
    detourPolicy: _detourPolicyFromRecord(j, unknown),
    url: _string(j['url']),
    meta: _metaFromRecord(j['meta'], where, notes),
    lastUpdated: _date(j['last_updated']),
    lastUpdateAttempt: _date(j['last_update_attempt']),
    lastUpdateStatus: UpdateStatus.values.firstWhere(
      (s) => s.name == j['last_update_status'],
      orElse: () => UpdateStatus.never,
    ),
    updateIntervalHours: interval is num ? interval.toInt() : 24,
    lastNodeCount: _int(j['last_node_count'], 0),
    consecutiveFails: _int(j['consecutive_fails'], 0),
    disabledHashes: _disabledFromRecord(j['disabled']),
    identity: _identityFromRecord(j['identity'], unknown),
    importRules: _importRulesFromRecord(j['import_rules'], where, notes),
    importRulesEnabled: _bool(j['import_rules_enabled'], true),
    onUpdateAction: SubscriptionOnUpdateAction.fromJson(j['on_update_action']),
  );
}

/// §439 п. 1 — узлы перечитываются из текста; `tag` записи на чтении не
/// применяется, расхождение с текстом называется в [notes].
UserServer _serverFromRecord(
  Map<String, dynamic> j,
  String id,
  List<String>? notes,
  List<String> unknown,
  List<NodeSectionDrop>? sectionDrops,
) {
  final where = 'server "$id"';
  _collectUnknown(j, _serverKeys, '', unknown);
  final raw = _rawOf(j, '', unknown);
  final nodes = _parseNodes(raw);
  _checkTag(j, nodes.isEmpty ? null : nodes.first.tag, where, notes);
  return UserServer(
    id: id,
    name: '',
    enabled: _bool(j['enabled'], true),
    tagPrefix: _prefixFromRecord(j['tag_policy'], unknown),
    detourPolicy: _detourPolicyFromRecord(j, unknown),
    rawBody: raw,
    sections: _sectionsFromRecord(j['sections'], where, notes, sectionDrops),
    // Список растущий: контроллер дописывает узлы на месте (как fromJson).
    nodes: [...nodes],
  );
}

FolderServers _folderFromRecord(
  Map<String, dynamic> j,
  String id,
  List<String>? notes,
  List<String> unknown,
  List<NodeSectionDrop>? sectionDrops,
) {
  final where = 'folder "$id"';
  _collectUnknown(j, _folderKeys, '', unknown);
  final members = <FolderMember>[];
  final rawNodes = j['nodes'];
  if (rawNodes is List) {
    for (var i = 0; i < rawNodes.length; i++) {
      final m = _memberFromRecord(
          rawNodes[i], id, where, i, notes, unknown, sectionDrops);
      if (m != null) members.add(m);
    }
  }
  final pingUrl = j['ping_url'];
  final pingTimeout = j['ping_timeout_ms'];
  return FolderServers(
    id: id,
    name: _string(j['name']),
    enabled: _bool(j['enabled'], true),
    tagPrefix: _prefixFromRecord(j['tag_policy'], unknown),
    detourPolicy: _detourPolicyFromRecord(j, unknown),
    members: members,
    // Пустой адрес — «брать глобальный», как у legacy-чтения.
    pingUrl: pingUrl is String && pingUrl.trim().isNotEmpty
        ? pingUrl.trim()
        : null,
    pingTimeoutMs: pingTimeout is num ? pingTimeout.toInt() : null,
    createdAt: _date(j['created_at']),
  );
}

/// Член папки. Вид записи на чтении не решает (текст побеждает): `server`
/// и `unsupported` читаются одинаково, запись без вида — тоже. `auto` —
/// член-группа; `chain` папка LxBox не держит — отброс с строкой в [notes].
FolderMember? _memberFromRecord(
  Object? raw,
  String folderId,
  String folderWhere,
  int index,
  List<String>? notes,
  List<String> unknown,
  List<NodeSectionDrop>? sectionDrops,
) {
  final where = '$folderWhere: nodes[$index]';
  final path = 'nodes[$index].';
  if (raw is! Map) {
    notes?.add('$where: not an object, dropped');
    return null;
  }
  final j = raw.cast<String, dynamic>();
  final kind = j['kind'];
  if (kind == kNodeKindAuto) {
    return autoGroupMemberFromRecord(j,
            folderId: folderId,
            where: where,
            notes: notes,
            unknown: unknown,
            path: path)
        .member;
  }
  if (kind is String &&
      kind != kSourceKindServer &&
      kind != kNodeKindUnsupported) {
    notes?.add('$where: kind "$kind" is not supported in a folder, dropped');
    return null;
  }
  _collectUnknown(j, _memberKeys, path, unknown);
  final member = FolderMember(
    raw: _rawOf(j, path, unknown),
    enabled: _bool(j['enabled'], true),
    detour: nodeLinkFromRecord(j['detour']) ?? NodeLink.none,
    sections: _sectionsFromRecord(j['sections'], where, notes, sectionDrops),
  );
  _checkTag(j, member.node?.tag, where, notes);
  return member;
}

/// Текст узла: `origin.raw`; у записи без исходника (форма лаунчера) —
/// `body` с тегом записи, сериализованный как JSON-outbound.
String _rawOf(Map<String, dynamic> j, String path, List<String> unknown) {
  final origin = j['origin'];
  if (origin is Map) {
    _collectUnknown(origin, const {'kind', 'raw'}, '${path}origin.', unknown);
    final raw = origin['raw'];
    if (raw is String && raw.isNotEmpty) return raw;
  }
  final body = j['body'];
  if (body is! Map) return '';
  final tag = j['tag'];
  return jsonEncode({
    if (tag is String && tag.isNotEmpty) 'tag': tag,
    for (final e in body.entries)
      if (e.key != 'tag' && e.key != 'detour') '${e.key}': e.value,
  });
}

void _checkTag(
  Map<String, dynamic> j,
  String? parsedTag,
  String where,
  List<String>? notes,
) {
  final tag = j['tag'];
  if (tag is! String || tag.isEmpty || parsedTag == null) return;
  if (tag != parsedTag) {
    notes?.add('$where: record tag "$tag" differs from the parsed node tag '
        '"$parsedTag", the text wins');
  }
}

/// §439 п. 9 — снимается ровно один хвостовой пробел (не `trimRight`):
/// префикс с пробелами, заданный через Debug API, не теряется.
String _prefixFromRecord(Object? policy, List<String> unknown) {
  if (policy is! Map) return '';
  _collectUnknown(policy, const {'prefix'}, 'tag_policy.', unknown);
  final p = policy['prefix'];
  if (p is! String) return '';
  return p.endsWith(' ') ? p.substring(0, p.length - 1) : p;
}

DetourPolicy _detourPolicyFromRecord(
  Map<String, dynamic> j,
  List<String> unknown,
) {
  final raw = j['detour_policy'];
  final p = raw is Map ? raw : const <String, dynamic>{};
  _collectUnknown(p, _detourPolicyKeys, 'detour_policy.', unknown);
  const d = DetourPolicy.defaults;
  return DetourPolicy(
    registerDetourServers:
        _bool(p['register_detour_servers'], d.registerDetourServers),
    registerDetourInAuto:
        _bool(p['register_detour_in_auto'], d.registerDetourInAuto),
    useDetourServers: _bool(p['use_detour_servers'], d.useDetourServers),
    overrideDetour: nodeLinkFromRecord(j['detour']) ?? NodeLink.none,
    replaceDetourChain: _bool(p['replace_detour_chain'], d.replaceDetourChain),
  );
}

SubscriptionIdentityOverride? _identityFromRecord(
  Object? raw,
  List<String> unknown,
) {
  if (raw is! Map) return null;
  _collectUnknown(raw, _identityKeys, 'identity.', unknown);
  return SubscriptionIdentityOverride(
    userAgent: _string(raw['user_agent']),
    sendHwid: _bool(raw['send_hwid'], false),
    hwid: _string(raw['hwid']),
    deviceOs: _string(raw['device_os']),
    verOs: _string(raw['ver_os']),
    deviceModel: _string(raw['device_model']),
  );
}

/// Отметки выключенных узлов: unix seconds → момент UTC. Пустой ключ и
/// значение не числом пропускаются: отметка без времени бесполезна для TTL.
Map<String, DateTime> _disabledFromRecord(Object? raw) {
  if (raw is! Map || raw.isEmpty) return const {};
  final out = <String, DateTime>{};
  raw.forEach((k, v) {
    final key = '$k';
    if (key.isEmpty || v is! num) return;
    out[key] =
        DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000, isUtc: true);
  });
  return out;
}

SubscriptionMeta? _metaFromRecord(
  Object? raw,
  String where,
  List<String>? notes,
) {
  if (raw is! Map) return null;
  try {
    return SubscriptionMeta.fromJson(raw.cast<String, dynamic>());
  } catch (_) {
    notes?.add('$where: meta does not read, dropped');
    return null;
  }
}

List<ImportRule> _importRulesFromRecord(
  Object? raw,
  String where,
  List<String>? notes,
) {
  if (raw is! List || raw.isEmpty) return const [];
  final out = <ImportRule>[];
  for (var i = 0; i < raw.length; i++) {
    final r = raw[i];
    try {
      if (r is! Map) throw const FormatException('not an object');
      out.add(ImportRule.fromJson(r.cast<String, dynamic>()));
    } catch (_) {
      notes?.add('$where: import_rules[$i] does not read, dropped');
    }
  }
  return out;
}

NodeSections? _sectionsFromRecord(
  Object? raw,
  String where,
  List<String>? notes,
  List<NodeSectionDrop>? drops,
) {
  final dropped = <String>[];
  final sections = NodeSections.fromJson(raw, dropped: dropped, drops: drops);
  for (final d in dropped) {
    notes?.add('$where: sections $d');
  }
  return sections;
}

/// Терпимое чтение ссылок папки [f] (NODE_LINK §7.3): S1 и S3 над её общим
/// detour и личными detour членов с кандидатами из членов этой же папки.
/// Ничего не поднялось — та же папка.
FolderServers liftFolderLinks(FolderServers f) {
  final raw = containerRawTags(f);
  final rawTags = raw.values.toSet();
  final groupForms = <String, List<String>>{};
  raw.forEach((node, tag) {
    if (!node.isGroup) return;
    (groupForms[containerFinalForm(f, tag)] ??= []).add(tag);
  });
  NodeLink lift(NodeLink l) => lowerGroupFinalLink(
      liftSiblingLink(l, f.id, rawTags), f.id, rawTags, groupForms);

  final override = lift(f.detourPolicy.overrideDetour);
  var changed = override != f.detourPolicy.overrideDetour;
  final members = [
    for (final m in f.members)
      if (lift(m.detour) case final d when d != m.detour)
        m.copyWith(detour: d)
      else
        m,
  ];
  if (!changed) {
    for (var i = 0; i < members.length; i++) {
      if (!identical(members[i], f.members[i])) changed = true;
    }
  }
  if (!changed) return f;
  return f.copyWith(
    detourPolicy: f.detourPolicy.copyWith(overrideDetour: override),
    members: members,
  );
}

// ─── помощники ──────────────────────────────────────────────────────────────

void _collectUnknown(
  Map<dynamic, dynamic> j,
  Set<String> known,
  String prefix,
  List<String> out,
) {
  for (final k in j.keys) {
    if (!known.contains(k)) out.add('$prefix$k');
  }
}

String _string(Object? v) => v is String ? v : '';

bool _bool(Object? v, bool fallback) => v is bool ? v : fallback;

int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
