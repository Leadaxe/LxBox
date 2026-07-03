import '../../models/custom_rule.dart';
import '../../models/parser_config.dart';
import '../json_clone.dart';
import 'if_engine.dart';

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
///    `dns_servers` через [substituteVars].
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
    // §045: `enabled: "@var"` convention — фрагмент пропускается если
    // var резолвится не в "true". Отсутствие поля = always-on.
    final enabledRaw = rs['enabled'];
    if (enabledRaw is String) {
      final substituted = substituteVars(enabledRaw, varsMap);
      if (substituted is! String || substituted.toLowerCase() != 'true') {
        continue;
      }
    } else if (enabledRaw is bool && !enabledRaw) {
      continue;
    }

    final copy = deepCopyJson(rs);
    final result = substituteVars(copy, varsMap);
    if (result is! Map<String, dynamic>) continue;
    if (result['tag'] is! String) continue;
    if (result['type'] is! String) continue;
    // sing-box не знает поля `enabled` на rule_set entry — strip перед
    // включением в финальный config (наша мета-конвенция, не sing-box).
    result.remove('enabled');

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
    final copy = deepCopyJson(preset.dnsRule!);
    final result = substituteVars(copy, varsMap);
    if (result is Map<String, dynamic> && result['server'] is String) {
      dnsRule = result;
    }
  }

  Map<String, dynamic>? routingRule;
  {
    final copy = deepCopyJson(preset.rule);
    final result = substituteVars(copy, varsMap);
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
      // через `substituteVars`, потому что preset может не иметь `@outbound`
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

      // ⚠ reject→action normalization — БЕЗУСЛОВНЫЙ backstop, НЕ удалять.
      //
      // `reject` в sing-box — это `action`, а НЕ outbound-tag. Правило
      // `{outbound: "reject"}` валидатор реджектит как dangling ref
      // (`DanglingOutboundRef`, validator.dart) → fatal → ядро не стартует.
      //
      // Override-ветка выше конвертит reject только когда юзер ЯВНО выбрал
      // его в OutboundPicker (`varsValues['outbound']` проставлен). Но `reject`
      // может прийти и template-дефолтом: пресет `unknown-traffic` имеет
      // `rule.outbound: "@outbound"` + var.default_value: "reject". Если юзер
      // просто включил пресет и не трогал пикер — ключа в `varsValues` нет,
      // override == null, ветка выше пропускается, а substitute уже подставил
      // `@outbound` → "reject" в `result['outbound']`. Без этого backstop'а
      // литерал `outbound: "reject"` уезжал в route.rules → fatal у юзеров
      // (см. §033 unknown-traffic). Поэтому нормализуем ФИНАЛЬНЫЙ результат
      // независимо от того, override это или дефолт.
      //
      // Это инвариант билдера (контракт sing-box reject=action), а НЕ забота
      // автора шаблона — поэтому фикс здесь, а не `#if` в wizard_template.json.
      if (result['outbound'] == 'reject') {
        result.remove('outbound');
        result['action'] = 'reject';
      }

      // Dangling-rule_set guard (§011 + §045): если ссылка на tag, которого
      // нет в expandedRuleSets — drop правила целиком (или выкинуть его из
      // массива). Иначе sing-box упадёт: `rule-set not found: <tag>`.
      //
      // Поддерживаются обе формы: String (один tag) и List<String> (массив,
      // OR-семантика sing-box'а). Из массива выживший один tag даунгрейдим
      // до String — идиоматичнее.
      final refTag = result['rule_set'];
      final expandedTags = {
        for (final rs in expandedRuleSets) rs['tag'] as String,
      };
      if (refTag is String && refTag.isNotEmpty) {
        if (!expandedTags.contains(refTag)) {
          warnings.add(
            'preset "${preset.presetId}": routing rule skipped — references '
            'missing rule_set "$refTag" (download SRS first)',
          );
        } else {
          routingRule = result;
        }
      } else if (refTag is List) {
        final present = refTag
            .whereType<String>()
            .where(expandedTags.contains)
            .toList();
        if (present.isEmpty) {
          warnings.add(
            'preset "${preset.presetId}": routing rule skipped — none of '
            '[${refTag.join(", ")}] available in expanded rule_sets',
          );
        } else {
          // Один остался → даунгрейд до string. >1 → оставляем массив.
          result['rule_set'] = present.length == 1 ? present.first : present;
          routingRule = result;
        }
      } else if (refTag == null) {
        // Легитимно: правило без `rule_set` матчит по другим полям
        // (domain/protocol/port/…). Оставляем как есть.
        routingRule = result;
      } else {
        // §219 — refTag не null, но и не валидная форма: пустая String либо
        // непредусмотренный тип (int/bool/Map из кривого шаблона). Раньше
        // молча проходило как валидное правило; теперь — drop + warning
        // (деградация вместо fatal, ср. §172/§217).
        result.remove('rule_set');
        warnings.add(
          'preset "${preset.presetId}": routing rule rule_set has invalid '
          'value (${refTag.runtimeType}) — reference dropped',
        );
        routingRule = result;
      }
    }
  }

  final selectedDns = varsMap['dns_server'] as String?;
  final dnsServers = <Map<String, dynamic>>[];
  if (selectedDns != null && selectedDns.isNotEmpty) {
    for (final s in preset.dnsServers) {
      if (s['tag'] != selectedDns) continue;
      final copy = deepCopyJson(s);
      final result = substituteVars(copy, varsMap);
      if (result is! Map<String, dynamic>) continue;
      if (result['tag'] is! String) continue;
      normalizeDnsDetour(result);
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
      } else if (!deepEqualsJson(existing, s)) {
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
      } else if (!deepEqualsJson(existing, rs)) {
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

/// §117: нормализация `detour` у DNS-сервера. Удаляет ключ когда:
/// - `direct-out` / пустая строка — direct не требует detour (решение №2:
///   «нет detour» = и дефолт, и fallback);
/// - канал отсутствует в [knownOutbounds] (выбранный канал исчез из конфига,
///   вкл. неотрезолвленный `@placeholder`) — отсутствие ключа вместо
///   dangling-ссылки.
///
/// Не-String detour не трогаем — невалидную форму поймает sing-box check.
void normalizeDnsDetour(
  Map<String, dynamic> server, {
  Set<String>? knownOutbounds,
}) {
  final detour = server['detour'];
  if (detour is! String) return;
  if (detour.isEmpty ||
      detour == 'direct-out' ||
      (knownOutbounds != null && !knownOutbounds.contains(detour))) {
    server.remove('detour');
  }
}

/// Рекурсивная подстановка `@var` + `#if` в JSON-фрагменте пресета.
///
/// §120: делегирует общему [walk]-движку ([if_engine.dart]) — тот же `#if`,
/// что и в config (единый механизм, не два параллельных). Контракт preset-нод
/// (отличается от build_config): значения в `vars` уже типизированы (приходят
/// из `WizardVar`-резолва пресета выше), а `null` для known-имени = optional-var
/// §033 → ключ/элемент выпадает.
///
/// Правила резолвера:
/// - `@name`, имя в `vars`, значение non-null → подставить значение;
/// - `@name`, имя в `vars`, значение null → [Dropped] (родитель удаляет);
/// - `@name`, имени нет в `vars` → оставить плейсхолдер (legacy/section-var);
/// - не-`@` строка → как есть.
dynamic substituteVars(dynamic obj, Map<String, dynamic> vars) {
  return walk(obj, (name) {
    if (!vars.containsKey(name)) return null; // unknown → keep placeholder
    final v = vars[name];
    if (v == null) return Dropped.instance; // optional-var §033 → drop
    return v;
  });
}

