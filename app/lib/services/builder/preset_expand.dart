import 'dart:convert';

import '../../models/custom_rule.dart';
import '../../models/parser_config.dart';

/// Результат expansion одного `CustomRule(kind: preset)` через его
/// `SelectableRule`-определение в шаблоне (spec §033).
///
/// Все поля — уже готовые к merge фрагменты с подставленными `@var`'ами.
/// `null` / пустой список = пресет не вносит этого типа содержимого
/// (например, optional var = null выкинул fragment целиком).
class PresetFragments {
  final List<Map<String, dynamic>> dnsServers;
  final Map<String, dynamic>? dnsRule;
  final List<Map<String, dynamic>> ruleSets;
  final Map<String, dynamic>? routingRule;
  final List<String> warnings;

  const PresetFragments({
    this.dnsServers = const [],
    this.dnsRule,
    this.ruleSets = const [],
    this.routingRule,
    this.warnings = const [],
  });

  bool get isEmpty =>
      dnsServers.isEmpty &&
      dnsRule == null &&
      ruleSets.isEmpty &&
      routingRule == null;
}

/// Результат merge всех preset-фрагментов от разных CustomRule'ов.
class BundleMerge {
  final List<Map<String, dynamic>> dnsServers;
  final List<Map<String, dynamic>> dnsRules;
  final List<Map<String, dynamic>> ruleSets;
  final List<Map<String, dynamic>> routingRules;
  final List<String> warnings;

  const BundleMerge({
    this.dnsServers = const [],
    this.dnsRules = const [],
    this.ruleSets = const [],
    this.routingRules = const [],
    this.warnings = const [],
  });
}

/// Pure-function expansion (spec §033).
///
/// Берёт `CustomRule(kind: preset)` + найденный по `presetId`
/// `SelectableRule`, возвращает подготовленные `PresetFragments`.
///
/// Алгоритм:
/// 1. Для каждой `preset.vars[i]` резолвим значение:
///    - есть в `rule.varsValues[name]` и не пустое → берём.
///    - иначе `required=true` → `defaultValue` (пустой → broken preset, warn).
///    - иначе `required=false` → `null` (при подстановке ключи с unresolved
///      `@var` удаляются из родительского Map).
/// 2. Deep-copy и substitute `@var` в `rule_set` / `dns_rule` / `rule` /
///    `dns_servers` через [_substitute].
/// 3. Фильтр `dns_servers` до одного — с `tag == vars['dns_server']`.
///    Если dns_server == null → пустой список (пресет не вносит DNS-сервер).
/// 4. Если `detour == 'direct-out'` в DNS-сервере — удаляем ключ (direct
///    не требует detour).
/// 5. Валидация критичных полей — если после substitute у `rule` нет
///    `outbound`/`action`, у `dns_rule` нет `server`, у DNS-сервера нет
///    `tag` → фрагмент отбрасывается.
/// `srsPaths` — mapping `rule_set.tag → local .srs path` для remote-rule_set'ов
/// пресета (pre-resolved через `RuleSetDownloader.cachedPathForPreset`).
/// Если pre-resolved path есть, `type: "remote"` в фрагменте заменяется на
/// `{type: "local", path: <cached>}` — sing-box ничего не качает сам
/// (spec §011 compliance). Если path нет, remote-rule_set пропускается +
/// warning: правило не активно до первого download'а через UI (spec §033,
/// task 011).
PresetFragments expandPreset(
  CustomRulePreset rule,
  SelectableRule preset, {
  Map<String, String> srsPaths = const {},
}) {
  final warnings = <String>[];

  final varsMap = <String, dynamic>{};
  for (final v in preset.vars) {
    // Семантика (spec §033):
    // - varsValues содержит ключ → юзер явно выбрал значение (включая "")
    //     - непустое → используется
    //     - пустое → "explicit none" (только для optional; required валидация
    //       не даст дойти сюда через UI)
    // - varsValues НЕ содержит ключ → юзер не трогал → применяется
    //   `default_value` (если пустой + required → error; пустой + optional
    //   → null = фрагменты с `@name` dropped)
    final hasExplicit = rule.varsValues.containsKey(v.name);
    final explicit = rule.varsValues[v.name];
    if (hasExplicit) {
      if (explicit == null || explicit.isEmpty) {
        if (v.required) {
          warnings.add(
            'preset "${preset.presetId}": required var "${v.name}" set to empty',
          );
          return PresetFragments(warnings: warnings);
        }
        varsMap[v.name] = null;
      } else {
        varsMap[v.name] = explicit;
      }
    } else if (v.defaultValue.isNotEmpty) {
      varsMap[v.name] = v.defaultValue;
    } else if (v.required) {
      warnings.add(
        'preset "${preset.presetId}": required var "${v.name}" unset',
      );
      return PresetFragments(warnings: warnings);
    } else {
      varsMap[v.name] = null;
    }
  }

  final expandedRuleSets = <Map<String, dynamic>>[];
  for (final rs in preset.ruleSets) {
    final copy = _deepCopy(rs);
    final result = _substitute(copy, varsMap);
    if (result is! Map<String, dynamic>) continue;
    if (result['tag'] is! String) continue;
    if (result['type'] is! String) continue;

    // Remote rule_set — заменяем на local через кэш (spec §011 compliance,
    // task 011). Без path → skip + warning: правило будет частично рабочим
    // (routing rule зарегистрируется, но rule_set не матчит).
    if (result['type'] == 'remote') {
      final tag = result['tag'] as String;
      final localPath = srsPaths[tag];
      if (localPath == null) {
        warnings.add(
          'preset "${preset.presetId}": remote rule_set "$tag" skipped — '
          'no cached file (download first)',
        );
        continue;
      }
      // Сохраняем tag/format/description, заменяем источник на local file.
      result
        ..['type'] = 'local'
        ..remove('url')
        ..remove('download_detour')
        ..remove('update_interval')
        ..['path'] = localPath;
      if (result['format'] is! String) {
        result['format'] = 'binary';
      }
    }
    expandedRuleSets.add(result);
  }

  Map<String, dynamic>? dnsRule;
  if (preset.dnsRule != null) {
    final copy = _deepCopy(preset.dnsRule!);
    final result = _substitute(copy, varsMap);
    if (result is Map<String, dynamic> && result['server'] is String) {
      dnsRule = result;
    }
  }

  Map<String, dynamic>? routingRule;
  {
    final copy = _deepCopy(preset.rule);
    final result = _substitute(copy, varsMap);
    if (result is Map<String, dynamic> &&
        (result['outbound'] is String || result['action'] is String)) {
      // Universal outbound override через `varsValues['outbound']` —
      // юзер всегда может заменить template-решение любым каналом
      // (reject → direct, direct → vpn-1, reject → vpn-2, и в обратную
      // сторону). Template-форма (`action: reject`, hardcoded outbound,
      // `@outbound`-placeholder) рассматривается как default; override
      // бьёт её полностью.
      //
      // `varsValues['outbound']` проверяется здесь, а не пропускается
      // через `_substitute`, потому что preset может не иметь `@outbound`
      // substitution (см. Block Ads: `rule: {rule_set, action: reject}`
      // без `vars`) — но override юзера всё равно должен применяться.
      //
      // Семантика:
      // - override пустой/отсутствует → template-решение as is
      // - override == "reject" → `action: reject`, `outbound` убирается
      //   (sing-box не принимает `outbound: "reject"` — это не tag'а)
      // - override == любой другой tag → `outbound: <tag>`, `action` убирается
      final override = rule.varsValues['outbound'];
      if (override != null && override.isNotEmpty) {
        result.remove('action');
        result.remove('outbound');
        if (override == 'reject') {
          result['action'] = 'reject';
        } else {
          result['outbound'] = override;
        }
      }

      // Dangling-rule_set guard: если `routing_rule.rule_set` ссылается на
      // tag, которого нет среди expanded rule-sets (например, remote
      // rule_set был skipped из-за отсутствующего cache) — drop routing
      // rule целиком. Иначе sing-box отказывается стартовать:
      // `initialize rule[N]: rule-set not found: <tag>` (task 011).
      final refTag = result['rule_set'];
      if (refTag is String && refTag.isNotEmpty) {
        final expandedTags = {
          for (final rs in expandedRuleSets) rs['tag'] as String,
        };
        if (!expandedTags.contains(refTag)) {
          warnings.add(
            'preset "${preset.presetId}": routing rule skipped — references '
            'missing rule_set "$refTag" (download SRS first)',
          );
        } else {
          routingRule = result;
        }
      } else {
        routingRule = result;
      }
    }
  }

  final selectedDns = varsMap['dns_server'] as String?;
  final dnsServers = <Map<String, dynamic>>[];
  if (selectedDns != null && selectedDns.isNotEmpty) {
    for (final s in preset.dnsServers) {
      if (s['tag'] != selectedDns) continue;
      final copy = _deepCopy(s);
      final result = _substitute(copy, varsMap);
      if (result is! Map<String, dynamic>) continue;
      if (result['tag'] is! String) continue;
      if (result['detour'] == 'direct-out') {
        result.remove('detour');
      }
      dnsServers.add(result);
    }
  }

  return PresetFragments(
    dnsServers: dnsServers,
    dnsRule: dnsRule,
    ruleSets: expandedRuleSets,
    routingRule: routingRule,
    warnings: warnings,
  );
}

/// Merge нескольких `PresetFragments` в финальные коллекции по правилам
/// spec §033:
/// - DNS-серверы и rule-sets дедуплицируются по `tag`: identical → silent
///   skip, non-identical под одним tag → first-wins + warning.
/// - DNS-rules и routing-rules append'ятся без дедупа (их order matters).
/// - Порядок определяется порядком входного списка (детерминированно).
BundleMerge mergeFragments(List<PresetFragments> all) {
  final dnsServers = <Map<String, dynamic>>[];
  final dnsServerByTag = <String, Map<String, dynamic>>{};
  final ruleSets = <Map<String, dynamic>>[];
  final ruleSetByTag = <String, Map<String, dynamic>>{};
  final dnsRules = <Map<String, dynamic>>[];
  final routingRules = <Map<String, dynamic>>[];
  final warnings = <String>[];

  for (final f in all) {
    warnings.addAll(f.warnings);

    for (final s in f.dnsServers) {
      final tag = s['tag'];
      if (tag is! String) {
        dnsServers.add(s);
        continue;
      }
      final existing = dnsServerByTag[tag];
      if (existing == null) {
        dnsServerByTag[tag] = s;
        dnsServers.add(s);
      } else if (!_deepEquals(existing, s)) {
        warnings.add('dns server "$tag" skipped: conflicts with earlier preset');
      }
    }

    for (final rs in f.ruleSets) {
      final tag = rs['tag'];
      if (tag is! String) {
        ruleSets.add(rs);
        continue;
      }
      final existing = ruleSetByTag[tag];
      if (existing == null) {
        ruleSetByTag[tag] = rs;
        ruleSets.add(rs);
      } else if (!_deepEquals(existing, rs)) {
        warnings.add('rule_set "$tag" skipped: conflicts with earlier preset');
      }
    }

    if (f.dnsRule != null) dnsRules.add(f.dnsRule!);
    if (f.routingRule != null) routingRules.add(f.routingRule!);
  }

  return BundleMerge(
    dnsServers: dnsServers,
    dnsRules: dnsRules,
    ruleSets: ruleSets,
    routingRules: routingRules,
    warnings: warnings,
  );
}

/// Sentinel: ключ/элемент был `@optional_var`, резолв дал `null` →
/// родитель должен удалить этот ключ/элемент.
class _Dropped {
  const _Dropped._();
  static const instance = _Dropped._();
}

/// Рекурсивная подстановка `@var` в JSON-фрагменте.
///
/// Правила:
/// - Строка `"@name"` (целиком) — заменяется на `vars[name]`. Если
///   `vars[name] == null` → возвращает [_Dropped.instance] (родитель
///   удаляет ключ / элемент списка).
/// - Строка не `@`-prefix'нутая — возвращается как есть.
/// - Unknown `@name` (ключа нет в varsMap) — возвращается как есть
///   (могли оставить legacy-плейсхолдер или имя глобальной section-var).
/// - Map / List — обход in-place, удаление dropped-ключей/элементов.
dynamic _substitute(dynamic obj, Map<String, dynamic> vars) {
  if (obj is String) {
    if (!obj.startsWith('@')) return obj;
    final name = obj.substring(1);
    if (!vars.containsKey(name)) return obj;
    final v = vars[name];
    if (v == null) return _Dropped.instance;
    return v;
  }

  if (obj is Map<String, dynamic>) {
    final toRemove = <String>[];
    for (final k in obj.keys.toList()) {
      final replaced = _substitute(obj[k], vars);
      if (identical(replaced, _Dropped.instance)) {
        toRemove.add(k);
      } else {
        obj[k] = replaced;
      }
    }
    for (final k in toRemove) {
      obj.remove(k);
    }
    return obj;
  }

  if (obj is List) {
    final compact = <dynamic>[];
    for (final e in obj) {
      final replaced = _substitute(e, vars);
      if (identical(replaced, _Dropped.instance)) continue;
      compact.add(replaced);
    }
    obj
      ..clear()
      ..addAll(compact);
    return obj;
  }

  return obj;
}

Map<String, dynamic> _deepCopy(Map<String, dynamic> src) =>
    jsonDecode(jsonEncode(src)) as Map<String, dynamic>;

bool _deepEquals(dynamic a, dynamic b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k)) return false;
      if (!_deepEquals(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
