import '../../config/consts.dart' show kDirectOutboundTag;
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

  /// DNS-правила пресета в порядке шаблона (§253: `dns_rule` может быть
  /// массивом `dns_rules` — напр. `[predefined-AAAA-#if, route]` у ru-direct).
  final List<Map<String, dynamic>> dnsRules;
  final List<Map<String, dynamic>> ruleSets;

  /// Route-правила пресета в порядке шаблона (§246: `rule` может быть
  /// массивом — напр. `[resolve ipv4_only, route]` у ru-direct).
  final List<Map<String, dynamic>> routingRules;
  final List<String> warnings;

  const PresetFragments({
    this.dnsServers = const [],
    this.dnsRules = const [],
    this.ruleSets = const [],
    this.routingRules = const [],
    this.warnings = const [],
  });

  bool get isEmpty =>
      dnsServers.isEmpty &&
      dnsRules.isEmpty &&
      ruleSets.isEmpty &&
      routingRules.isEmpty;
}

/// §246: не-терминальные route rule actions sing-box 1.14 — правило
/// продолжает матчинг дальше по цепочке (в отличие от route/reject/
/// hijack-dns). Outbound-override и reject-backstop к ним не применяются.
const _kIntermediateActions = {'resolve', 'sniff', 'route-options'};

/// §253: DNS rule actions, которым `server` не нужен. Закрытый список —
/// у ядра `route` И `evaluate` без server = fatal на старте, а неизвестный
/// action = decode error; опечатка в шаблоне не должна доезжать до ядра.
const _kServerlessDnsActions = {'predefined', 'reject', 'route-options'};

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
/// 2. Deep-copy и substitute `@var` в `rule_set` / `dns_rules` / `rule` /
///    `dns_servers` через [substituteVars].
/// 3. Фильтр `dns_servers`: пресет БЕЗ var'а `dns_server` (§354 — сервер
///    зашит литералом в правилах) эмитит ВСЕ объявленные; пресет С var'ом —
///    только выбранный (`dns_server == null` → пустой список). §354: если
///    выбранный — группа (§312), вместе с ней едут её члены (одноуровнево),
///    иначе группа приедет пустой → EmptyDnsGroup (fatal).
/// 4. Если `detour == 'direct-out'` в DNS-сервере — удаляем ключ (direct
///    не требует detour).
/// 5. Валидация критичных полей — если после substitute у `rule` нет
///    `outbound`/`action`, у DNS-правила нет ни `server`, ни serverless
///    `action` (§253), у DNS-сервера нет `tag` → фрагмент отбрасывается.
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
  Map<String, String> globalVars = const {},
}) {
  final warnings = <String>[];

  final varsMap = <String, dynamic>{};
  for (final v in preset.vars) {
    // §265 — ref-var: значение НЕ в rule.varsValues (оно в глобальном
    // userVars). Локальный varsMap пресета его не несёт: `@<ref>` в правилах
    // пресета резолвится позже из flat-vars build_config'а (globalVars,
    // передаются отдельно — см. параметр globalVars ниже).
    if (v.isRef) continue;
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

  // §265 — ref-vars: подмешиваем значение из глобального userVars по имени
  // (globalVars) в локальный varsMap, чтобы `@<ref>` в правилах пресета
  // резолвился глобальным значением (напр. `@resolve_strategy` в route-resolve
  // = та же настройка, что и `config.dns.strategy`). Пустое/отсутствующее →
  // null (фрагмент с `@ref` выпадет, как optional-var).
  for (final v in preset.vars) {
    if (!v.isRef) continue;
    final gv = globalVars[v.ref];
    varsMap[v.name] = (gv != null && gv.isNotEmpty) ? gv : null;
  }

  // §264 — глобальные vars как FALLBACK: правила пресета могут содержать
  // глобальные плейсхолдеры, не объявленные среди preset.vars — прежде всего
  // `@vpn_mode` в `#if`-гейте inbound (`tun-in`/`mixed-in`). Раньше эти правила
  // жили в `config.route.rules` (глобальный substitute, где vpn_mode есть);
  // переехав в пресет traffic-processing (§264), они потеряли бы доступ →
  // `#if @vpn_mode` не резолвится → inbound[] пустеет. Подмешиваем globalVars,
  // НЕ перетирая локальные preset-vars (putIfAbsent).
  for (final e in globalVars.entries) {
    varsMap.putIfAbsent(e.key, () => e.value);
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

  final expandedTags = {
    for (final rs in expandedRuleSets) rs['tag'] as String,
  };

  // §253: DNS-правила — тот же array-walk, что у route-правил §246 ниже
  // (array-element `#if` force_ipv4-гейта AAAA-правила ru-direct: false без
  // else → элемент выпадает из массива).
  final dnsRules = <Map<String, dynamic>>[];
  {
    final copy = <dynamic>[for (final r in preset.dnsRules) deepCopyJson(r)];
    final substituted = substituteVars(copy, varsMap);
    final items = substituted is List ? substituted : const [];
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final result = item;
      // Валидность элемента: `server` (route-семантика) ИЛИ serverless
      // action из закрытого списка. Ни того ни другого (optional-var
      // выпал / кривой шаблон / опечатка в action) → drop silently
      // (§033 — прежний гейт `server is String` для single-формы).
      final action = result['action'];
      final serverless =
          action is String && _kServerlessDnsActions.contains(action);
      if (result['server'] is! String && !serverless) continue;

      // Dangling-rule_set guard — паритет с route-правилами (§011/§045):
      // DNS-правило со ссылкой на незарегистрированный tag уронило бы ядро
      // на старте (у legacy single-формы guard'а не было — повезло, что
      // ru-direct ссылается только на inline-set'ы).
      final refTag = result['rule_set'];
      if (refTag is String && refTag.isNotEmpty) {
        if (!expandedTags.contains(refTag)) {
          warnings.add(
            'preset "${preset.presetId}": DNS rule skipped — references '
            'missing rule_set "$refTag" (download SRS first)',
          );
          continue;
        }
      } else if (refTag is List) {
        final present = refTag
            .whereType<String>()
            .where(expandedTags.contains)
            .toList();
        if (present.isEmpty) {
          warnings.add(
            'preset "${preset.presetId}": DNS rule skipped — none of '
            '[${refTag.join(", ")}] available in expanded rule_sets',
          );
          continue;
        }
        result['rule_set'] = present.length == 1 ? present.first : present;
      } else if (refTag != null) {
        // §219-паритет с route-правилами: невалидная форма (пустая String,
        // int/bool/Map из кривого шаблона) → снимаем ссылку, правило живёт
        // (деградация вместо fatal «rule-set not found» у ядра).
        result.remove('rule_set');
        warnings.add(
          'preset "${preset.presetId}": DNS rule rule_set has invalid '
          'value (${refTag.runtimeType}) — reference dropped',
        );
      }
      dnsRules.add(result);
    }
  }

  final routingRules = <Map<String, dynamic>>[];
  {
    // §246: substitute гоняется по массиву ЦЕЛИКОМ — array-element `#if`
    // (гейт `{"and": ["@force_ipv4"]}` у resolve-правила ru-direct/ru-inside)
    // живёт в обходе List: false без else → элемент выпадает (Dropped).
    // Поэлементный substitute сломал бы гейт — standalone-Map `#if`
    // мержится map-spread'ом (false → пустой Map), а не выпадает.
    // <dynamic>: if_engine._walkList мутирует список in-place через
    // addAll(List<dynamic>) — типизированный List<Map> тут упадёт на cast.
    final copy = <dynamic>[for (final r in preset.rules) deepCopyJson(r)];
    final substituted = substituteVars(copy, varsMap);
    final items = substituted is List ? substituted : const [];
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final result = item;
      if (result['outbound'] is! String && result['action'] is! String) {
        // После substitute нет ни outbound, ни action (optional-var
        // выпал / кривой шаблон) → элемент дропается silently (§033).
        continue;
      }

      // §246: промежуточные правила (resolve/sniff/route-options) не
      // роутят — outbound-override и reject-backstop к ним не применяются
      // (override заменил бы `action: resolve` на outbound юзера и убил
      // семантику). Их присутствие в конфиге решает `#if`-гейт шаблона
      // (ru-direct/ru-inside: resolve эмитится по bool-var `@force_ipv4`).
      final isIntermediate = _kIntermediateActions.contains(result['action']);
      if (!isIntermediate) {
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
      }

      // Dangling-rule_set guard (§011 + §045): если ссылка на tag, которого
      // нет в expandedRuleSets — drop правила целиком (или выкинуть его из
      // массива). Иначе sing-box упадёт: `rule-set not found: <tag>`.
      // §246: guard поэлементный — битый элемент дропается, остальные живут.
      //
      // Поддерживаются обе формы: String (один tag) и List<String> (массив,
      // OR-семантика sing-box'а). Из массива выживший один tag даунгрейдим
      // до String — идиоматичнее.
      final refTag = result['rule_set'];
      if (refTag is String && refTag.isNotEmpty) {
        if (!expandedTags.contains(refTag)) {
          warnings.add(
            'preset "${preset.presetId}": routing rule skipped — references '
            'missing rule_set "$refTag" (download SRS first)',
          );
        } else {
          routingRules.add(result);
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
          routingRules.add(result);
        }
      } else if (refTag == null) {
        // Легитимно: правило без `rule_set` матчит по другим полям
        // (domain/protocol/port/…). Оставляем как есть.
        routingRules.add(result);
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
        routingRules.add(result);
      }
    }
  }

  // Какие из `preset.dns_servers` эмитим.
  //
  // Пресет БЕЗ var'а `dns_server` (§354: ru-direct — группа зашита литералом
  // в правилах) → эмитим ВСЕ объявленные: выбирать нечего, а недоэмиссия
  // оставила бы правило со ссылкой в пустоту.
  //
  // Пресет С var'ом (fakeip и пр.) → только выбранный (контракт §033). Если
  // выбранный — ГРУППА (§312), вместе с ней едут её члены: без них группа
  // приедет пустой (эмиссионный фильтр §312 выкинет их как unknown, дальше
  // validator упрётся в EmptyDnsGroup — fatal до старта ядра). Одноуровнево:
  // вложенных групп в шаблоне нет, а ядро вложенность разворачивает само.
  final hasDnsServerVar = preset.vars.any((v) => v.name == 'dns_server');
  final selectedDns = varsMap['dns_server'] as String?;
  Set<String>? wanted; // null = без фильтра (эмитим все)
  if (hasDnsServerVar) {
    wanted = {};
    if (selectedDns != null && selectedDns.isNotEmpty) {
      wanted.add(selectedDns);
      for (final s in preset.dnsServers) {
        if (s['tag'] != selectedDns) continue;
        if (s['type'] != 'group') break;
        for (final m in (s['servers'] as List<dynamic>? ?? const [])) {
          if (m is String && m.isNotEmpty) wanted.add(m);
        }
        break;
      }
    }
  }

  // Порядок как в шаблоне (группа объявлена перед членами); дедуп по тегу
  // делает mergeFragments.
  final dnsServers = <Map<String, dynamic>>[];
  for (final s in preset.dnsServers) {
    if (wanted != null && !wanted.contains(s['tag'])) continue;
    final copy = deepCopyJson(s);
    final result = substituteVars(copy, varsMap);
    if (result is! Map<String, dynamic>) continue;
    if (result['tag'] is! String) continue;
    normalizeDnsDetour(result);
    dnsServers.add(result);
  }

  return PresetFragments(
    dnsServers: dnsServers,
    dnsRules: dnsRules,
    ruleSets: expandedRuleSets,
    routingRules: routingRules,
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

    dnsRules.addAll(f.dnsRules); // §253: порядок внутри пресета сохранён
    routingRules.addAll(f.routingRules); // §246: порядок внутри пресета сохранён
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
  // §319 — у DNS-ГРУППЫ detour'а нет по определению: своего транспорта у неё
  // не бывает, запросы несут участники (каждый со своим detour). Ядро
  // принимает у `type: group` ровно {servers, mode, error_ttl, win_ttl}
  // (kernel SPEC 033) и падает на лишнем ключе — «start» отваливался с
  // ошибкой, стоило выбрать не-direct канал. Чистим ЗДЕСЬ, а не только в
  // форме: у пострадавших ключ уже лежит в storage, и без этого конфиг
  // оставался бы битым до ручного захода в редактор.
  if (server['type'] == 'group') {
    server.remove('detour');
    return;
  }
  final detour = server['detour'];
  if (detour is! String) return;
  if (detour.isEmpty ||
      detour == kDirectOutboundTag ||
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

