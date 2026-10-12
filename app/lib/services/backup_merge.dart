import 'dart:convert';

import 'json_clone.dart';
import 'settings_storage_keys.dart';

/// §633 — слияние документа настроек при импорте бэкапа в режиме Merge.
///
/// Правило одно для всех ключей: Merge добавляет то, чего у получателя нет, и
/// не трогает то, что у него есть. Списки сливаются по идентичности записи,
/// скаляры — «есть у получателя → его значение».
///
/// | ключ | идентичность | что берётся из файла |
/// |---|---|---|
/// | `rules` | пресет — `ref`; прочие — `id` или содержательный отпечаток | новые правила — в конец пользовательской зоны оси `num`; пресет: включённость «включён у кого-либо», параметры выключенного у получателя — из файла |
/// | `directions` | `tag` | новые теги в конец; тег, занятый цепочкой получателя, пропускается |
/// | `dns.servers` | `tag`, у preset — `ref` | новые в конец |
/// | `dns.rules` | preset — `ref`, template — `name`, прочие — `id` или отпечаток | новые в конец |
/// | `tun_apps` | пакет | объединение пакетов; режим получателя, если он не `off` |
/// | `sources` | `id`, у цепочки — `tag` | новые в конец (вход Debug API; UI сливает источники на моделях) |
/// | `vars` | подключ | отсутствующие у получателя подключи |
/// | прочие ключи | ключ | только отсутствующие у получателя |
///
/// [current] мутируется на месте. [incoming] не меняется (записи из него
/// клонируются).
StorageMergeStats mergeStorageDoc(
  Map<String, dynamic> current,
  Map<String, dynamic> incoming,
) {
  final stats = StorageMergeStats();
  for (final entry in incoming.entries) {
    final key = entry.key;
    final value = entry.value;
    if (value == null) continue;
    if (key == kStorageVersionKey) {
      // Форма — свойство документа получателя; файл её не меняет.
      current.putIfAbsent(key, () => value);
      continue;
    }
    final have = current[key];
    if (key == kRulesKey && value is List && have is List) {
      _mergeRules(current[key] = _list(have), value, stats.rules);
      continue;
    }
    if (key == 'directions' && value is List && have is List) {
      _mergeDirections(
        current[key] = _list(have),
        value,
        _chainTags(current),
        stats.directions,
      );
      continue;
    }
    if (key == kDnsKey && value is Map && have is Map) {
      _mergeDns(current[key] = _map(have), value, stats);
      continue;
    }
    if (key == 'tun_apps' && value is Map && have is Map) {
      _mergeTunApps(current[key] = _map(have), value, stats.tunApps);
      continue;
    }
    if (key == kSourcesKey && value is List && have is List) {
      _mergeSources(
        current[key] = _list(have),
        value,
        _directionTags(current),
        stats.sources,
      );
      continue;
    }
    if (key == 'vars' && value is Map) {
      if (have is Map) {
        final vars = current[key] = _map(have);
        for (final v in value.entries) {
          final vk = v.key.toString();
          if (vars.containsKey(vk)) {
            stats.keptKeys.add('vars.$vk');
          } else {
            vars[vk] = deepCloneJson(v.value);
            stats.addedKeys.add('vars.$vk');
          }
        }
        continue;
      }
      // У получателя `vars` нет — берётся целиком: все подключи новые.
      current[key] = deepCloneJson(value);
      for (final vk in value.keys) {
        stats.addedKeys.add('vars.$vk');
      }
      continue;
    }

    if (have != null) {
      stats.keptKeys.add(key);
      continue;
    }
    current[key] = deepCloneJson(value);
    // Список, которого у получателя не было, — записи считаются добавленными.
    final count = _countFor(key, value, stats);
    if (count == null) stats.addedKeys.add(key);
  }
  return stats;
}

/// Изменяемые копии верхнего уровня: в документе могут лежать типизированные
/// коллекции (литералы вызывающего), а слияние дописывает в них `dynamic`.
List<dynamic> _list(List l) => List<dynamic>.of(l);
Map<String, dynamic> _map(Map m) => {
  for (final e in m.entries) e.key.toString(): e.value,
};

/// Счётчик пары «добавлено / уже было» для одной группы записей.
class MergeCount {
  int added = 0;
  int kept = 0;

  Map<String, int> toJson() => {'added': added, 'kept': kept};
}

/// §633 — итог [mergeStorageDoc]: сколько записей добавлено и сколько
/// пропущено как уже существующие, по группам. Скалярные ключи — списками
/// имён (`vars.<k>` для подключей `vars`), категорию им назначает вызывающий.
class StorageMergeStats {
  final sources = MergeCount();
  final rules = MergeCount();
  final directions = MergeCount();
  final dnsServers = MergeCount();
  final dnsRules = MergeCount();

  /// Пакеты Tunnel apps.
  final tunApps = MergeCount();

  /// Скалярные ключи и подключи `vars`, взятые из файла (у получателя их не
  /// было).
  final addedKeys = <String>[];

  /// Скалярные ключи и подключи `vars`, которые есть у обеих сторон: значение
  /// получателя осталось.
  final keptKeys = <String>[];

  Map<String, Object> toJson() => {
    'sources': sources.toJson(),
    'rules': rules.toJson(),
    'directions': directions.toJson(),
    'dns_servers': dnsServers.toJson(),
    'dns_rules': dnsRules.toJson(),
    'tun_apps': tunApps.toJson(),
    'keys': {'added': addedKeys.length, 'kept': keptKeys.length},
  };
}

/// Ключ-список, которого у получателя не было: записи — в нужный счётчик.
/// null — ключ не списочный, считается как скаляр.
int? _countFor(String key, Object value, StorageMergeStats stats) {
  MergeCount? c;
  var n = 0;
  if (key == kRulesKey && value is List) {
    c = stats.rules;
    n = value.length;
  } else if (key == 'directions' && value is List) {
    c = stats.directions;
    n = value.length;
  } else if (key == kSourcesKey && value is List) {
    c = stats.sources;
    n = value.length;
  } else if (key == 'tun_apps' && value is Map) {
    c = stats.tunApps;
    final p = value['packages'];
    n = p is List ? p.length : 0;
  } else if (key == kDnsKey && value is Map) {
    final s = value[kDnsServersKey];
    final r = value[kDnsRulesKey];
    stats.dnsServers.added += s is List ? s.length : 0;
    stats.dnsRules.added += r is List ? r.length : 0;
    return 0;
  }
  if (c == null) return null;
  c.added += n;
  return n;
}

// ─────────────────────────────── правила ───────────────────────────────

/// Зона пользовательских правил оси `num` (§370, `kUserRuleNumStart` /
/// `kUserRuleNumEnd` в `parser_config.dart`). Здесь числами: модуль работает
/// над JSON и не тянет модели.
const _userNumStart = 1000;
const _userNumEnd = 1100;

void _mergeRules(List have, List incoming, MergeCount c) {
  final presetAt = <String, Map>{};
  final ids = <String>{};
  final prints = <String>{};
  var maxUserNum = _userNumStart - 1;
  for (final r in have) {
    if (r is! Map) continue;
    if (r['kind'] == 'preset' && r['ref'] is String) {
      presetAt[r['ref'] as String] = r;
      continue;
    }
    final id = r['id'];
    if (id is String && id.isNotEmpty) ids.add(id);
    prints.add(_fingerprint(r, const {'id', 'num', 'enabled'}));
    final n = r['num'];
    if (n is num && n >= _userNumStart && n <= _userNumEnd && n > maxUserNum) {
      maxUserNum = n.toInt();
    }
  }
  var nextNum = maxUserNum + 1;

  for (final r in incoming) {
    if (r is! Map) continue;
    if (r['kind'] == 'preset' && r['ref'] is String) {
      final ref = r['ref'] as String;
      final mine = presetAt[ref];
      if (mine == null) {
        // Пресета у получателя нет — приезжает со своим номером шаблона.
        final added = deepCloneJson(r) as Map;
        have.add(added);
        presetAt[ref] = added;
        c.added++;
        continue;
      }
      // Включён у кого-либо → включён. Параметры — того, у кого он включён;
      // включён у обоих или выключен у обоих — параметры получателя.
      if (mine['enabled'] != true && r['enabled'] == true) {
        mine['enabled'] = true;
        if (r.containsKey('vars')) {
          mine['vars'] = deepCloneJson(r['vars']);
        } else {
          mine.remove('vars');
        }
      }
      c.kept++;
      continue;
    }
    final id = r['id'];
    final print = _fingerprint(r, const {'id', 'num', 'enabled'});
    if ((id is String && ids.contains(id)) || prints.contains(print)) {
      c.kept++;
      continue;
    }
    // Новое правило — в конец пользовательских: свои правила остаются выше
    // по приоритету. Зона исчерпана — номер на границе, порядок доопределяет
    // позиция в списке (стабильная сортировка, `sortRulesByNum`).
    final added = deepCloneJson(r) as Map;
    added['num'] = nextNum > _userNumEnd ? _userNumEnd : nextNum;
    nextNum++;
    have.add(added);
    if (id is String && id.isNotEmpty) ids.add(id);
    prints.add(print);
    c.added++;
  }
}

// ────────────────────────────── Направления ─────────────────────────────

void _mergeDirections(
  List have,
  List incoming,
  Set<String> chainTags,
  MergeCount c,
) {
  final tags = <String>{
    for (final d in have)
      if (d is Map && d['tag'] is String) d['tag'] as String,
  };
  for (final d in incoming) {
    if (d is! Map) continue;
    final tag = d['tag'];
    if (tag is! String || tags.contains(tag) || chainTags.contains(tag)) {
      // Тег уже есть (в том числе `vpn-1`) или занят цепочкой получателя:
      // два outbound с одним тегом сломали бы конфиг.
      c.kept++;
      continue;
    }
    have.add(deepCloneJson(d));
    tags.add(tag);
    c.added++;
  }
}

// ──────────────────────────────── DNS ────────────────────────────────

void _mergeDns(Map have, Map incoming, StorageMergeStats stats) {
  for (final entry in incoming.entries) {
    final k = entry.key;
    final v = entry.value;
    final mine = have[k];
    if (k == kDnsServersKey && v is List && mine is List) {
      _mergeKeyed(have[k] = _list(mine), v, _dnsServerKey, stats.dnsServers);
    } else if (k == kDnsRulesKey && v is List && mine is List) {
      _mergeKeyed(have[k] = _list(mine), v, _dnsRuleKey, stats.dnsRules);
    } else if (mine == null && v != null) {
      have[k] = deepCloneJson(v);
      if (k == kDnsServersKey && v is List) stats.dnsServers.added += v.length;
      if (k == kDnsRulesKey && v is List) stats.dnsRules.added += v.length;
    }
  }
}

String? _dnsServerKey(Map r) {
  final tag = r['tag'];
  if (tag is String && tag.isNotEmpty) return 'tag:$tag';
  final ref = r['ref'];
  if (ref is String && ref.isNotEmpty) return 'tag:$ref';
  return null;
}

String? _dnsRuleKey(Map r) {
  final kind = r['kind'];
  if (kind == 'preset' && r['ref'] is String) return 'preset:${r['ref']}';
  if (kind == 'template' && r['name'] is String) {
    return 'template:${r['name']}';
  }
  final id = r['id'];
  if (id is String && id.isNotEmpty) return 'id:$id';
  return null;
}

/// Слить список записей: запись совпадает с записью получателя по ключу
/// [keyOf] или по содержательному отпечатку (без `enabled`). Новые — в конец.
void _mergeKeyed(
  List have,
  List incoming,
  String? Function(Map r) keyOf,
  MergeCount c,
) {
  final keys = <String>{};
  final prints = <String>{};
  for (final r in have) {
    if (r is! Map) continue;
    final k = keyOf(r);
    if (k != null) keys.add(k);
    prints.add(_fingerprint(r, const {'enabled'}));
  }
  for (final r in incoming) {
    if (r is! Map) continue;
    final k = keyOf(r);
    final print = _fingerprint(r, const {'enabled'});
    if ((k != null && keys.contains(k)) || prints.contains(print)) {
      c.kept++;
      continue;
    }
    have.add(deepCloneJson(r));
    if (k != null) keys.add(k);
    prints.add(print);
    c.added++;
  }
}

// ───────────────────────────── Tunnel apps ─────────────────────────────

void _mergeTunApps(Map have, Map incoming, MergeCount c) {
  final mine = <String>[
    for (final p in (have['packages'] as List?) ?? const [])
      if (p is String) p,
  ];
  final set = mine.toSet();
  for (final p in (incoming['packages'] as List?) ?? const []) {
    if (p is! String || p.trim().isEmpty) continue;
    if (set.add(p)) {
      mine.add(p);
      c.added++;
    } else {
      c.kept++;
    }
  }
  // Нормальная форма сеттера `setTunApps`: без повторов, по алфавиту.
  have['packages'] = mine..sort();
  final myMode = have['mode'];
  final theirMode = incoming['mode'];
  if ((myMode == null || myMode == 'off') &&
      (theirMode == 'allow' || theirMode == 'deny')) {
    have['mode'] = theirMode;
  }
}

// ────────────────────────────── источники ──────────────────────────────

void _mergeSources(
  List have,
  List incoming,
  Set<String> directionTags,
  MergeCount c,
) {
  final keys = <String>{
    for (final r in have)
      if (r is Map && _sourceKey(r) != null) _sourceKey(r)!,
  };
  for (final r in incoming) {
    if (r is! Map) continue;
    final k = _sourceKey(r) ?? 'print:${_fingerprint(r, const {})}';
    final chainTag = r['kind'] == 'chain' ? r['tag'] : null;
    if (keys.contains(k) ||
        (chainTag is String && directionTags.contains(chainTag))) {
      c.kept++;
      continue;
    }
    have.add(deepCloneJson(r));
    keys.add(k);
    c.added++;
  }
}

String? _sourceKey(Map r) {
  if (r['kind'] == 'chain') {
    final tag = r['tag'];
    return tag is String ? 'chain:$tag' : null;
  }
  final id = r['id'];
  return id is String && id.isNotEmpty ? 'id:$id' : null;
}

Set<String> _chainTags(Map<String, dynamic> doc) => {
  for (final r in (doc[kSourcesKey] as List?) ?? const [])
    if (r is Map && r['kind'] == 'chain' && r['tag'] is String)
      r['tag'] as String,
};

Set<String> _directionTags(Map<String, dynamic> doc) => {
  for (final d in (doc['directions'] as List?) ?? const [])
    if (d is Map && d['tag'] is String) d['tag'] as String,
};

// ────────────────────────────── отпечаток ──────────────────────────────

/// Содержательный отпечаток записи: канонический JSON (ключи по алфавиту на
/// всех уровнях) без полей [ignore] верхнего уровня.
String _fingerprint(Map r, Set<String> ignore) {
  final m = <String, Object?>{
    for (final e in r.entries)
      if (!ignore.contains(e.key.toString())) e.key.toString(): e.value,
  };
  return jsonEncode(_canon(m));
}

Object? _canon(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _canon(v[k])};
  }
  if (v is List) return [for (final e in v) _canon(e)];
  return v;
}
