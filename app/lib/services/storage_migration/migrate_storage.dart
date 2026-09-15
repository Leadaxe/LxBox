/// Миграция документа хранения формы 2.23.2 в форму контракта 1.0 (§439 §3).
///
/// Чистая функция над документом: `lxbox_settings.json` на диске, файл слота
/// Workspaces, блок `storage` внутреннего бэкапа, тело Debug
/// `POST /backup/import`. Файлы, копия `.v0.bak` и журнал — у вызывающего
/// (`settings_storage/io.dart`).
///
/// Путь данных: замороженный читатель 2.23.2 (`legacy_form_v0.dart`) →
/// модели → кодек записей (`models/codec/`). Что прочитано не дословно,
/// называется в [StorageMigrationResult.warnings] с именами записей.
library;

import '../../models/auto_select.dart';
import '../../models/codec/auto_group_record.dart';
import '../../models/codec/chain_record.dart';
import '../../models/codec/dns_record.dart';
import '../../models/codec/rule_record.dart';
import '../../models/codec/source_record.dart';
import '../../models/custom_rule.dart';
import '../../models/direction.dart' show StickyHashKey, UrltestMode;
import '../../models/dns_ref.dart';
import '../../models/node_link.dart';
import '../../models/node_spec.dart';
import '../../models/parser_config.dart' show SelectableRule;
import '../../models/server_list.dart';
import '../json_clone.dart' show deepCloneJson;
import '../node_identity.dart';
import '../parser/body_decoder.dart';
import '../parser/parse_all.dart';
import '../parser/uri_utils.dart' show newUuidV4, tagFromLabel;
import '../settings_storage_keys.dart';
import 'legacy_form_v0.dart';

/// Ключи формы 2.23.2, которые миграция переводит в записи 1.0.
const Set<String> kLegacyStorageKeys = {
  _kServerLists,
  _kChains,
  _kCustomRules,
  _kDnsOptions,
};

const _kServerLists = 'server_lists';
const _kChains = 'chains';
const _kCustomRules = 'custom_rules';
const _kDnsOptions = 'dns_options';

/// Легаси-имена состава Направлений (до §393 A2).
const _kLegacyDirections = 'channels';
const _kLegacyDirectionsMigrated = 'channels_migrated';

/// Ключи без читателей (§439 §1.1): удаляются миграцией.
const Set<String> _kDeadTopLevelKeys = {
  'excluded_nodes',
  'preset_ids_remapped',
  'proxy_sources',
  'app_rules',
  'enabled_rules',
  'rule_outbounds',
  'node_overrides',
  'show_detour_servers',
};

/// Подключи `vars` без читателей.
const Set<String> _kDeadVarKeys = {'auto_rebuild'};

/// Итог [migrateStorageDoc].
final class StorageMigrationResult {
  const StorageMigrationResult({
    required this.doc,
    required this.migrated,
    this.foundVersion,
    this.info = const [],
    this.warnings = const [],
  });

  /// Документ формы 1.0. Без миграции — входной документ как есть (тот же
  /// объект), иначе новая карта; вход не мутируется.
  final Map<String, dynamic> doc;

  /// Документ изменён: не было `storage_version` или были ключи 2.23.2.
  final bool migrated;

  /// `storage_version` входа; null — ключа нет (форма 2.23.2).
  final int? foundVersion;

  /// Что сделано: счётчики записей, переименования, удалённые ключи.
  final List<String> info;

  /// Что прочитано не дословно или потеряно, с именами записей.
  final List<String> warnings;

  /// Отчёт одной строкой (журнал).
  String get summary => info.join('; ');

  /// Отчёт для ответа Debug API.
  Map<String, dynamic> toReportJson() => {
        'migrated': migrated,
        if (foundVersion != null) 'found_version': foundVersion,
        if (info.isNotEmpty) 'info': info,
        if (warnings.isNotEmpty) 'warnings': warnings,
      };
}

/// Тег preset-сервера DNS → `preset_id` пресета шаблона, который его объявляет
/// (`selectable_rules[].dns_servers[].tag`). Первый объявивший побеждает.
Map<String, String> presetIdsByDnsServerTag(Iterable<SelectableRule> presets) {
  final out = <String, String>{};
  for (final p in presets) {
    for (final s in p.dnsServers) {
      final tag = s['tag'];
      if (tag is String && tag.isNotEmpty) {
        out.putIfAbsent(tag, () => p.presetId);
      }
    }
  }
  return out;
}

/// `storage_version` документа; null — ключа нет или значение не версия
/// (целое от 1).
int? storageDocVersion(Map<String, dynamic> doc) {
  final v = doc[kStorageVersionKey];
  return v is int && v >= 1 ? v : null;
}

/// Нужна ли документу [migrateStorageDoc]: нет версии, есть ключи 2.23.2
/// или члены папок `autogroup://` (§439 N2). Дёшево — без разбора записей.
bool storageDocNeedsMigration(Map<String, dynamic> doc) =>
    storageDocVersion(doc) == null ||
    kLegacyStorageKeys.any(doc.containsKey) ||
    _hasLegacyAutogroups(doc[kSourcesKey]);

/// §439 §3.1 п. 3 — документ хранения → форма 1.0.
///
/// - Есть `storage_version` и нет ключей 2.23.2 — документ не трогается;
///   исключение — члены папок `autogroup://` в `sources[]` (записи ранних
///   сборок 2.23.3), их переводит [migrateAutogroupMembers].
/// - Нет `storage_version` — `server_lists`/`chains` → `sources[]` (цепочки
///   хвостом в порядке старого `order`), `custom_rules` → `rules[]`,
///   `dns_options` → `dns{servers, rules}` с `ref` preset-серверов по
///   [presetIdByDnsServerTag] (пресет не найден — `ref` = тег); ставится
///   `storage_version: 1`.
/// - Есть `storage_version` и ключи 2.23.2 (2.23.2 поверх данных 2.23.3,
///   §3.2) — ключи 2.23.2 отбрасываются с предупреждением, записи
///   `sources`/`rules`/`dns` остаются, версия не меняется.
///
/// В обоих случаях миграции удаляются ключи без читателей, а
/// `channels`/`channels_migrated` становятся `directions`/`directions_migrated`,
/// если новых имён нет.
///
/// Идемпотентна: результат, поданный снова, не меняется. Не бросает: битая
/// запись отбрасывается с предупреждением (исходник остаётся в `.v0.bak`).
StorageMigrationResult migrateStorageDoc(
  Map<String, dynamic> doc, {
  Map<String, String> presetIdByDnsServerTag = const {},
}) {
  final version = storageDocVersion(doc);
  final legacyPresent = [
    for (final k in kLegacyStorageKeys)
      if (doc.containsKey(k)) k,
  ];
  if (version != null && legacyPresent.isEmpty) {
    final sources = doc[kSourcesKey];
    if (sources is! List || !_hasLegacyAutogroups(sources)) {
      return StorageMigrationResult(
          doc: doc, migrated: false, foundVersion: version);
    }
    final info = <String>[];
    final warnings = <String>[];
    final out = deepCloneJson(doc) as Map<String, dynamic>;
    out[kSourcesKey] = migrateAutogroupMembers(
      [
        for (final e in out[kSourcesKey] as List)
          if (e is Map) e.cast<String, dynamic>(),
      ],
      info,
      warnings,
    );
    return StorageMigrationResult(
      doc: out,
      migrated: true,
      foundVersion: version,
      info: info,
      warnings: warnings,
    );
  }

  final info = <String>[];
  final warnings = <String>[];
  final convert = version == null;

  final rawVersion = doc[kStorageVersionKey];
  if (rawVersion != null && version == null) {
    warnings.add('storage_version "$rawVersion" is not a version, '
        'the document is read as the legacy form');
  }

  List<Map<String, dynamic>>? sources;
  List<Map<String, dynamic>>? rules;
  Map<String, dynamic>? dns;
  if (convert) {
    if (doc.containsKey(_kServerLists) || doc.containsKey(_kChains)) {
      sources = migrateAutogroupMembers(
          _convertSources(doc, info, warnings), info, warnings);
    }
    if (doc.containsKey(_kCustomRules)) {
      rules = _convertRules(doc[_kCustomRules], info, warnings);
    }
    if (doc.containsKey(_kDnsOptions)) {
      dns = _convertDns(
          doc[_kDnsOptions], presetIdByDnsServerTag, info, warnings);
    }
  } else {
    warnings.add('storage_version $version with legacy keys '
        '${legacyPresent.join(', ')}: legacy keys dropped, '
        'records in $kSourcesKey/$kRulesKey/$kDnsKey kept');
  }

  final dropped = <String>[];
  final renamed = <String>[];
  // §393 A2 — легаси-пара рядом со списком Направлений (перенесённым из
  // `channels` или уже лежащим под `directions`) ставила guard
  // `directions_migrated: true` независимо от значения `channels_migrated`:
  // прерванная установка писала список без маркера. Переименование держит то
  // же, иначе список остался бы без guard'а.
  final legacyDirectionsGuard = (doc.containsKey(_kLegacyDirections) ||
          doc.containsKey(_kLegacyDirectionsMigrated)) &&
      !doc.containsKey('directions_migrated') &&
      (doc['directions'] is List ||
          (doc[_kLegacyDirections] is List && !doc.containsKey('directions')));
  final out = <String, dynamic>{
    kStorageVersionKey: version ?? kStorageVersion,
  };
  for (final e in doc.entries) {
    final key = e.key;
    switch (key) {
      case kStorageVersionKey:
        break;
      case _kServerLists || _kChains:
        // Записи цепочек идут хвостом `sources[]` (§439 п. 7): ключ встаёт
        // на место первого из двух.
        if (sources != null && !out.containsKey(kSourcesKey)) {
          out[kSourcesKey] = sources;
        }
      case _kCustomRules:
        if (rules != null) out[kRulesKey] = rules;
      case _kDnsOptions:
        if (dns != null) out[kDnsKey] = dns;
      case kSourcesKey when sources != null:
      case kRulesKey when rules != null:
      case kDnsKey when dns != null:
        warnings.add('"$key" without storage_version is replaced by '
            'the legacy keys of the same document');
      case _kLegacyDirections:
        // §393 A2 — новое имя сильнее легаси.
        if (e.value != null && !doc.containsKey('directions')) {
          out['directions'] = deepCloneJson(e.value);
          renamed.add('$key → directions');
        } else {
          dropped.add(key);
        }
      case _kLegacyDirectionsMigrated:
        if (e.value != null && !doc.containsKey('directions_migrated')) {
          out['directions_migrated'] =
              legacyDirectionsGuard ? true : deepCloneJson(e.value);
          renamed.add('$key → directions_migrated');
        } else {
          dropped.add(key);
        }
      case 'vars':
        final vars = e.value;
        if (vars is! Map) {
          out[key] = deepCloneJson(vars);
          break;
        }
        final outVars = <String, dynamic>{};
        for (final v in vars.entries) {
          if (_kDeadVarKeys.contains(v.key)) {
            dropped.add('vars.${v.key}');
          } else {
            outVars['${v.key}'] = deepCloneJson(v.value);
          }
        }
        out[key] = outVars;
      default:
        if (_kDeadTopLevelKeys.contains(key)) {
          dropped.add(key);
        } else {
          out[key] = deepCloneJson(e.value);
        }
    }
  }

  if (legacyDirectionsGuard && !out.containsKey('directions_migrated')) {
    out['directions_migrated'] = true;
  }

  if (renamed.isNotEmpty) info.add('renamed: ${renamed.join(', ')}');
  if (dropped.isNotEmpty) info.add('dropped keys: ${dropped.join(', ')}');

  return StorageMigrationResult(
    doc: out,
    migrated: true,
    foundVersion: version,
    info: info,
    warnings: warnings,
  );
}

// ─── sources ────────────────────────────────────────────────────────────────

List<Map<String, dynamic>> _convertSources(
  Map<String, dynamic> doc,
  List<String> info,
  List<String> warnings,
) {
  final out = <Map<String, dynamic>>[];
  var subscriptions = 0, servers = 0, folders = 0;
  final multiNode = <String>[];

  final rawLists = doc[_kServerLists];
  if (rawLists != null && rawLists is! List) {
    warnings.add('$_kServerLists is not a list, dropped');
  }
  if (rawLists is List) {
    for (var i = 0; i < rawLists.length; i++) {
      final raw = rawLists[i];
      if (raw is! Map) {
        warnings.add('$_kServerLists[$i]: not an object, dropped');
        continue;
      }
      final j = raw.cast<String, dynamic>();
      try {
        final list = readLegacyServerList(j);
        out.add(sourceToRecord(list));
        switch (list) {
          case SubscriptionServers():
            subscriptions++;
          case UserServer():
            servers++;
            if (list.nodes.length > 1) multiNode.add(list.id);
          case FolderServers():
            folders++;
        }
      } catch (e) {
        warnings.add('$_kServerLists[$i] ${_sourceName(j)}: '
            'does not read ($e), dropped');
      }
    }
  }

  final rawChains = doc[_kChains];
  if (rawChains != null && rawChains is! List) {
    warnings.add('$_kChains is not a list, dropped');
  }
  final chains = <LegacyChain>[];
  if (rawChains is List) {
    for (var i = 0; i < rawChains.length; i++) {
      final raw = rawChains[i];
      if (raw is! Map) {
        warnings.add('$_kChains[$i]: not an object, dropped');
        continue;
      }
      try {
        final c = readLegacyChain(raw.cast<String, dynamic>());
        if (c.chain.tag.isEmpty) {
          warnings.add('$_kChains[$i]: chain without tag, dropped');
          continue;
        }
        chains.add(c);
      } catch (e) {
        warnings.add('$_kChains[$i] "${raw['tag']}": does not read ($e), '
            'dropped');
      }
    }
  }
  for (final c in sortLegacyChains(chains)) {
    out.add(chainToRecord(c));
  }

  info.add('$kSourcesKey: $subscriptions subscriptions, '
      '$servers servers, $folders folders, ${chains.length} chains');
  if (multiNode.isNotEmpty) {
    info.add('servers with several nodes kept as one record: '
        '${multiNode.length} (${multiNode.join(', ')})');
  }
  return out;
}

String _sourceName(Map<String, dynamic> j) {
  final id = j['id'];
  final name = j['name'];
  return '(${j['type']} id "$id"${name is String && name.isNotEmpty ? ' "$name"' : ''})';
}

// ─── autogroup (§439 N2) ────────────────────────────────────────────────────

/// Схема члена-группы папки в хранении до §439 N2 (`FolderMember.raw`).
const String _kLegacyAutogroupScheme = 'autogroup://';

bool _isLegacyAutogroup(Object? node) {
  if (node is! Map) return false;
  final origin = node['origin'];
  final raw = origin is Map ? origin['raw'] : null;
  return raw is String &&
      raw.trimLeft().toLowerCase().startsWith(_kLegacyAutogroupScheme);
}

bool _hasLegacyAutogroups(Object? sources) =>
    sources is List &&
    sources.any((s) =>
        s is Map &&
        s['kind'] == kSourceKindFolder &&
        s['nodes'] is List &&
        (s['nodes'] as List).any(_isLegacyAutogroup));

/// §439 N2 — шаг миграции над записями `sources[]`: член папки с исходником
/// `autogroup://…` (текст, которым группа хранилась до N2; разбор снят, и
/// кодек читает такой член `unsupported`) → запись `kind: auto`
/// (`codec/auto_group_record.dart`).
///
/// - `RuleMembers` (`include`/`exclude`, «все члены») переносится как есть.
/// - Явный состав — ключи `protocol|server|port|credential` — становится
///   парами `{id папки, тег}` по узлам той же папки (`nodeIdentityKey` над
///   разобранными членами). Ключ нескольких членов решает включённый, если
///   он один (его и собирала сборка). Ключ без члена, неоднозначный ключ,
///   член без тега или с тегом, который носит ещё кто-то в папке, — строка в
///   [warnings], член из состава снимается.
/// - Нечитаемый текст группы — строка в [warnings], член снимается (текст
///   остаётся в `.v0.bak`).
///
/// Идемпотентен: записей `autogroup://` в результате нет.
List<Map<String, dynamic>> migrateAutogroupMembers(
  List<Map<String, dynamic>> sources,
  List<String> info,
  List<String> warnings,
) {
  var converted = 0;
  final out = <Map<String, dynamic>>[];
  for (final source in sources) {
    final nodes = source['nodes'];
    if (source['kind'] != kSourceKindFolder ||
        nodes is! List ||
        !nodes.any(_isLegacyAutogroup)) {
      out.add(source);
      continue;
    }
    final folderId = source['id'] is String ? source['id'] as String : '';
    final name = source['name'];
    final where = 'folder "${name is String && name.isNotEmpty ? name : folderId}"';
    final parsed = [
      for (final n in nodes) _isLegacyAutogroup(n) ? null : _recordNode(n),
    ];
    final next = <Object?>[];
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      if (!_isLegacyAutogroup(n)) {
        next.add(n);
        continue;
      }
      final record = _autogroupRecord(
        (n as Map).cast<String, dynamic>(),
        nodes,
        parsed,
        folderId,
        '$where: nodes[$i]',
        warnings,
      );
      if (record != null) {
        next.add(record);
        converted++;
      }
    }
    out.add({...source, 'nodes': next});
  }
  if (converted > 0) {
    info.add('auto nodes: $converted autogroup members → kind auto');
  }
  return out;
}

/// Узел члена папки из исходника записи; нет исходника или не разобрался —
/// `null`.
NodeSpec? _recordNode(Object? node) {
  if (node is! Map) return null;
  final origin = node['origin'];
  final raw = origin is Map ? origin['raw'] : null;
  if (raw is! String || raw.trim().isEmpty) return null;
  try {
    final nodes = parseAll(decode(raw));
    return nodes.isEmpty ? null : nodes.first;
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? _autogroupRecord(
  Map<String, dynamic> node,
  List<dynamic> nodes,
  List<NodeSpec?> parsed,
  String folderId,
  String where,
  List<String> warnings,
) {
  final raw = ((node['origin'] as Map)['raw'] as String).trim();
  final legacy = _readLegacyAutogroup(raw);
  if (legacy == null) {
    warnings.add('$where: autogroup text does not read, dropped '
        '(the text stays in .v0.bak)');
    return null;
  }
  final label = legacy.label.isEmpty ? 'Auto' : legacy.label;
  final tag = tagFromLabel(label, 'urltest', 'auto', 0);
  final keys = legacy.keys;
  final AutoSelectMembership membership;
  if (keys == null) {
    membership = RuleMembers(include: legacy.include, exclude: legacy.exclude);
  } else {
    final links = <NodeLink>[];
    for (final key in keys) {
      final link = _linkOfKey(key, nodes, parsed, folderId);
      if (link.error != null) {
        warnings.add('$where "$tag": member ${link.error}, dropped');
        continue;
      }
      if (!links.contains(link.link)) links.add(link.link!);
    }
    membership = ExplicitMembers(links);
  }
  if (node['detour'] != null || node['sections'] != null) {
    warnings.add('$where "$tag": detour and sections of an auto node '
        'are dropped');
  }
  final group = AutoSelectSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    membership: membership,
    params: legacy.params,
    poolBadge: legacy.poolBadge,
  );
  final enabled = node['enabled'];
  return autoGroupMemberToRecord(
    FolderMember.auto(group, enabled: enabled is bool ? enabled : true),
    group,
    folderId,
  );
}

/// Ключ `protocol|server|port|credential` → пара на члена папки.
({NodeLink? link, String? error}) _linkOfKey(
  String key,
  List<dynamic> nodes,
  List<NodeSpec?> parsed,
  String folderId,
) {
  bool enabledAt(int i) {
    final n = nodes[i];
    return !(n is Map && n['enabled'] == false);
  }

  var hits = [
    for (var i = 0; i < parsed.length; i++)
      if (parsed[i] case final n? when nodeIdentityKey(n) == key) i,
  ];
  // Сборка до N2 брала только включённых членов.
  if (hits.length > 1) hits = hits.where(enabledAt).toList();
  if (hits.isEmpty) return (link: null, error: 'key "$key" matches no node');
  if (hits.length > 1) {
    return (
      link: null,
      error: 'key "$key" matches ${hits.length} nodes',
    );
  }
  final tag = parsed[hits.single]!.tag;
  if (tag.isEmpty) return (link: null, error: 'key "$key" has an untagged node');
  final sameTag = parsed.where((n) => n?.tag == tag).length;
  if (sameTag > 1) {
    return (link: null, error: 'tag "$tag" is carried by $sameTag nodes');
  }
  return (link: NodeLink(folderId: folderId, tag: tag), error: null);
}

/// Разбор `autogroup://?members=…|include=…&mode=…#Label` — замороженная
/// форма 2.23.2 (`autoGroupFromUri`). [keys] `null` — режим правила.
({
  String label,
  List<String>? keys,
  String include,
  String exclude,
  AutoSelectParams params,
  String poolBadge,
})? _readLegacyAutogroup(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null) return null;
  try {
    final q = uri.queryParameters;
    const d = AutoSelectParams();
    final rawMembers = q['members'];
    final sticky = q['sticky'];
    return (
      label: Uri.decodeComponent(uri.fragment),
      // §352 — узкое экранирование ключа: `,` и `%`.
      keys: rawMembers?.split(',')
          .map((e) =>
              e.trim().replaceAll('%2C', ',').replaceAll('%25', '%'))
          .where((e) => e.isNotEmpty)
          .toList(),
      include: q['include'] ?? '',
      exclude: q['exclude'] ?? '',
      params: AutoSelectParams(
        url: q['url'] ?? d.url,
        interval: q['interval'] ?? d.interval,
        tolerance: int.tryParse(q['tolerance'] ?? '') ?? d.tolerance,
        idleTimeout: q['idle_timeout'] ?? d.idleTimeout,
        interruptExistConnections: q['interrupt'] == '1',
        mode: UrltestMode.fromWire(q['mode']),
        pool: int.tryParse(q['pool'] ?? '') ?? d.pool,
        poolTolerance: clampPoolTolerance(
            int.tryParse(q['pool_tolerance'] ?? '') ?? d.poolTolerance),
        stickyHash: sticky == null
            ? d.stickyHash
            : sticky
                .split(',')
                .map((k) => StickyHashKey.fromWire(k.trim()))
                .whereType<StickyHashKey>()
                .toList(),
      ),
      poolBadge: q['badge'] ?? kDefaultPoolBadge,
    );
  } catch (_) {
    return null;
  }
}

// ─── rules ──────────────────────────────────────────────────────────────────

List<Map<String, dynamic>> _convertRules(
  Object? raw,
  List<String> info,
  List<String> warnings,
) {
  if (raw is! List) {
    warnings.add('$_kCustomRules is not a list, dropped');
    return [];
  }
  final out = <Map<String, dynamic>>[];
  var read = 0;
  final split = <String>[];
  for (var i = 0; i < raw.length; i++) {
    final e = raw[i];
    if (e is! Map) {
      warnings.add('$_kCustomRules[$i]: not an object, dropped');
      continue;
    }
    final CustomRule rule;
    try {
      rule = readLegacyCustomRule(e.cast<String, dynamic>());
    } catch (err) {
      warnings.add('$_kCustomRules[$i] "${e['name']}": does not read ($err), '
          'dropped');
      continue;
    }
    read++;
    try {
      if (rule is CustomRuleJson) {
        final records = _jsonRuleRecords(rule, warnings);
        if (records.length > 1) split.add('"${rule.name}" → ${records.length}');
        out.addAll(records);
        continue;
      }
      final badPorts = [
        for (final p in rule.ports)
          if (!_isPort(p)) p,
      ];
      if (badPorts.isNotEmpty) {
        warnings.add('rule "${rule.name}": non-numeric ports dropped: '
            '${badPorts.join(', ')}');
      }
      out.add(ruleToRecord(rule));
    } catch (err) {
      warnings.add('rule "${rule.name}": does not convert ($err), dropped');
    }
  }
  info.add('$kRulesKey: $read rules → ${out.length} records');
  if (split.isNotEmpty) info.add('json rules split: ${split.join(', ')}');
  return out;
}

bool _isPort(String p) {
  final n = int.tryParse(p);
  return n != null && n >= 0 && n <= 65535;
}

/// §439 §2.3 п. 3, В2 — json-правило: объект → одна запись `verbatim` с
/// телом; массив с объектами → по записи на объект ([splitJsonRuleArrays] —
/// тот же путь, что у сохранения правил); прочее → маркер `verbatim` без тела.
List<Map<String, dynamic>> _jsonRuleRecords(
  CustomRuleJson rule,
  List<String> warnings,
) {
  final records = [
    for (final r in splitJsonRuleArrays([rule], notes: warnings))
      ruleToRecord(r),
  ];
  if (records.length == 1 &&
      !records.single.containsKey('body') &&
      rule.json.trim().isNotEmpty) {
    warnings.add('rule "${rule.name}": raw JSON is not an object or an array '
        'of objects, kept without body (the text stays in .v0.bak)');
  }
  return records;
}

// ─── dns ────────────────────────────────────────────────────────────────────

Map<String, dynamic> _convertDns(
  Object? raw,
  Map<String, String> presetIdByTag,
  List<String> info,
  List<String> warnings,
) {
  if (raw is! Map) {
    warnings.add('$_kDnsOptions is not an object, dropped');
    return {};
  }
  final out = <String, dynamic>{};
  var servers = 0, rules = 0;
  final noPreset = <String>[];

  final rawServers = raw['servers'];
  if (rawServers is List) {
    final list = <Map<String, dynamic>>[];
    for (var i = 0; i < rawServers.length; i++) {
      final e = rawServers[i];
      if (e is! Map) {
        warnings.add('dns server [$i]: not an object, dropped');
        continue;
      }
      final j = e.cast<String, dynamic>();
      try {
        var ref = readLegacyDnsServer(j);
        if (ref == null) {
          warnings.add('dns server [$i] "${j['tag']}": '
              '${j['kind'] == null ? 'record without kind (old form)' : 'kind "${j['kind']}" or required fields missing'}, '
              'dropped');
          continue;
        }
        if (ref is DnsServerPreset) {
          final presetId = presetIdByTag[ref.tag] ?? '';
          if (presetId.isEmpty) noPreset.add(ref.tag);
          ref = ref.copyWith(presetId: presetId);
        }
        list.add(dnsServerToRecord(ref));
        servers++;
      } catch (err) {
        warnings.add('dns server [$i] "${j['tag']}": does not read ($err), '
            'dropped');
      }
    }
    out[kDnsServersKey] = list;
  } else if (rawServers != null) {
    warnings.add('$_kDnsOptions.servers is not a list, dropped');
  }

  final rawRules = raw['rules'];
  if (rawRules is List) {
    final list = <Map<String, dynamic>>[];
    for (var i = 0; i < rawRules.length; i++) {
      final e = rawRules[i];
      if (e is! Map) {
        warnings.add('dns rule [$i]: not an object, dropped');
        continue;
      }
      final j = e.cast<String, dynamic>();
      final name = j['name'] ?? j['presetId'];
      try {
        final ref = readLegacyDnsRule(j);
        if (ref == null) {
          warnings.add('dns rule [$i] "$name": kind "${j['kind']}" '
              'is an old form or required fields are missing, dropped');
          continue;
        }
        list.add(dnsRuleToRecord(ref));
        rules++;
      } catch (err) {
        warnings.add('dns rule [$i] "$name": does not read ($err), dropped');
      }
    }
    out[kDnsRulesKey] = list;
  } else if (rawRules != null) {
    warnings.add('$_kDnsOptions.rules is not a list, dropped');
  }

  for (final k in raw.keys) {
    // `rules_json` не читается с §061: удаляется молча.
    if (k == 'servers' || k == 'rules' || k == 'rules_json') continue;
    warnings.add('$_kDnsOptions.$k: unknown key, dropped');
  }

  info.add('$kDnsKey: $servers servers, $rules rules');
  if (noPreset.isNotEmpty) {
    info.add('dns preset servers without a known preset (ref = tag): '
        '${noPreset.join(', ')}');
  }
  return out;
}
