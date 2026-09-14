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

import 'dart:convert';

import '../../models/codec/chain_record.dart';
import '../../models/codec/dns_record.dart';
import '../../models/codec/rule_record.dart';
import '../../models/codec/source_record.dart';
import '../../models/custom_rule.dart';
import '../../models/dns_ref.dart';
import '../../models/parser_config.dart' show SelectableRule;
import '../../models/server_list.dart';
import '../json_clone.dart' show deepCloneJson;
import 'legacy_form_v0.dart';

/// Версия формы хранения, которую пишет эта сборка.
const int kStorageVersion = 1;

/// Ключи верхнего уровня формы 1.0, которые знает миграция.
///
/// До влития волны B3a имена живут здесь одним местом; у репозиториев
/// хранения — свои константы тех же имён.
abstract final class StorageDocKeys {
  static const version = 'storage_version';
  static const sources = 'sources';
  static const rules = 'rules';
  static const dns = 'dns';
}

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

  /// `storage_version` больше известной: документ читается как текущий.
  bool get isNewerThanKnown =>
      foundVersion != null && foundVersion! > kStorageVersion;

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
  final v = doc[StorageDocKeys.version];
  return v is int && v >= 1 ? v : null;
}

/// Нужна ли документу [migrateStorageDoc]: нет версии или есть ключи 2.23.2.
/// Дёшево — без разбора записей.
bool storageDocNeedsMigration(Map<String, dynamic> doc) =>
    storageDocVersion(doc) == null || kLegacyStorageKeys.any(doc.containsKey);

/// §439 §3.1 п. 3 — документ хранения → форма 1.0.
///
/// - Есть `storage_version` и нет ключей 2.23.2 — документ не трогается.
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
    return StorageMigrationResult(
        doc: doc, migrated: false, foundVersion: version);
  }

  final info = <String>[];
  final warnings = <String>[];
  final convert = version == null;

  final rawVersion = doc[StorageDocKeys.version];
  if (rawVersion != null && version == null) {
    warnings.add('storage_version "$rawVersion" is not a version, '
        'the document is read as the legacy form');
  }

  List<Map<String, dynamic>>? sources;
  List<Map<String, dynamic>>? rules;
  Map<String, dynamic>? dns;
  if (convert) {
    if (doc.containsKey(_kServerLists) || doc.containsKey(_kChains)) {
      sources = _convertSources(doc, info, warnings);
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
        'records in ${StorageDocKeys.sources}/${StorageDocKeys.rules}/'
        '${StorageDocKeys.dns} kept');
  }

  final dropped = <String>[];
  final renamed = <String>[];
  final out = <String, dynamic>{
    StorageDocKeys.version: version ?? kStorageVersion,
  };
  for (final e in doc.entries) {
    final key = e.key;
    switch (key) {
      case StorageDocKeys.version:
        break;
      case _kServerLists || _kChains:
        // Записи цепочек идут хвостом `sources[]` (§439 п. 7): ключ встаёт
        // на место первого из двух.
        if (sources != null && !out.containsKey(StorageDocKeys.sources)) {
          out[StorageDocKeys.sources] = sources;
        }
      case _kCustomRules:
        if (rules != null) out[StorageDocKeys.rules] = rules;
      case _kDnsOptions:
        if (dns != null) out[StorageDocKeys.dns] = dns;
      case StorageDocKeys.sources when sources != null:
      case StorageDocKeys.rules when rules != null:
      case StorageDocKeys.dns when dns != null:
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
          out['directions_migrated'] = deepCloneJson(e.value);
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

  info.add('${StorageDocKeys.sources}: $subscriptions subscriptions, '
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
  info.add('${StorageDocKeys.rules}: $read rules → ${out.length} records');
  if (split.isNotEmpty) info.add('json rules split: ${split.join(', ')}');
  return out;
}

bool _isPort(String p) {
  final n = int.tryParse(p);
  return n != null && n >= 0 && n <= 65535;
}

/// §439 §2.3 п. 3, В2 — json-правило: объект → одна запись `verbatim` с
/// телом; массив → по записи на объект (`<имя>`, `<имя> #2`, …; первая
/// держит `id`, `enabled` и `num` общие); прочее → маркер `verbatim` без тела.
List<Map<String, dynamic>> _jsonRuleRecords(
  CustomRuleJson rule,
  List<String> warnings,
) {
  Object? decoded;
  try {
    decoded = jsonDecode(rule.json.trim());
  } catch (_) {
    decoded = null;
  }
  if (decoded is Map) return [ruleToRecord(rule)];
  if (decoded is List) {
    final bodies = decoded.whereType<Map>().toList();
    final skipped = decoded.length - bodies.length;
    if (skipped > 0) {
      warnings.add('rule "${rule.name}": $skipped non-object element(s) of '
          'the JSON array dropped');
    }
    if (bodies.isNotEmpty) {
      return [
        for (var i = 0; i < bodies.length; i++)
          ruleToRecord(CustomRuleJson(
            id: i == 0 ? rule.id : null,
            name: i == 0 ? rule.name : '${rule.name} #${i + 1}',
            enabled: rule.enabled,
            orderNum: rule.orderNum,
            json: jsonEncode(bodies[i]),
          )),
      ];
    }
  }
  if (rule.json.trim().isNotEmpty) {
    warnings.add('rule "${rule.name}": raw JSON is not an object or an array '
        'of objects, kept without body (the text stays in .v0.bak)');
  }
  return [ruleToRecord(rule)];
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
    out['servers'] = list;
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
    out['rules'] = list;
  } else if (rawRules != null) {
    warnings.add('$_kDnsOptions.rules is not a list, dropped');
  }

  for (final k in raw.keys) {
    // `rules_json` не читается с §061: удаляется молча.
    if (k == 'servers' || k == 'rules' || k == 'rules_json') continue;
    warnings.add('$_kDnsOptions.$k: unknown key, dropped');
  }

  info.add('${StorageDocKeys.dns}: $servers servers, $rules rules');
  if (noPreset.isNotEmpty) {
    info.add('dns preset servers without a known preset (ref = tag): '
        '${noPreset.join(', ')}');
  }
  return out;
}
