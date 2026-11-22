part of '../post_steps.dart';

/// Post-step: expansion + merge bundle-пресетов (spec §033).
///
/// Для каждого `CustomRule(kind: preset, enabled: true)` ищет
/// соответствующий `SelectableRule` по `presetId`, разворачивает
/// через [expandPreset], merge'ит через [mergeFragments]. Результирующие
/// rule-sets и routing rules регистрирует в [registry] (rule-sets через
/// [RuleSetRegistry.tryRegisterRuleSet] — identical-skip / first-wins).
/// Extra DNS-данные возвращаются вверх — инжектируются [applyCustomDns].
///
/// Broken preset (`presetId` не найден в шаблоне) пропускается с warning;
/// UI показывает broken-card для таких правил.
PresetApplyResult applyPresetBundles(
  RuleSetRegistry registry,
  List<CustomRule> rules,
  List<SelectableRule> presets, {
  Map<String, String> presetSrsPaths = const {},
}) {
  // §062: shim вокруг `_applyPresetSingle` — обходит ТОЛЬКО preset rules
  // в storage order (фильтруя inline/srs). Сохраняет старый publi API +
  // backward-compat для тестов. Real pipeline использует [applyAllCustomRules]
  // которое обходит все kinds в одном цикле сохраняя cross-kind order.
  final state = _PresetSharedState();
  final warnings = <String>[];
  for (final cr in rules) {
    if (cr is! CustomRulePreset) continue;
    warnings.addAll(_applyPresetSingle(
      cr,
      registry,
      presets,
      state,
      presetSrsPaths: presetSrsPaths,
    ));
  }
  return PresetApplyResult(
    extraDnsServers: state.dnsServers,
    dnsServerPresetIdByTag: state.dnsServerPresetIdByTag,
    extraDnsRules: state.dnsRules,
    dnsRulesByPresetId: state.dnsRulesByPresetId,
    labelByPresetId: state.labelByPresetId,
    warnings: warnings,
  );
}

/// §062: shared state, накапливаемый across preset rules (cross-preset
/// dedup для DNS servers + agg для DNS rules / labels). Передаётся в
/// `_applyPresetSingle` чтобы обработка одного preset видела что уже
/// зарегистрировано предыдущими.
class _PresetSharedState {
  final List<Map<String, dynamic>> dnsServers = [];
  final Map<String, Map<String, dynamic>> dnsServerByTag = {};

  /// §439 — тег DNS-сервера → `preset_id` пресета, который внёс его первым.
  final Map<String, String> dnsServerPresetIdByTag = {};
  final List<Map<String, dynamic>> dnsRules = [];
  // §253: пресет может нести несколько DNS-правил (порядок шаблона).
  final Map<String, List<Map<String, dynamic>>> dnsRulesByPresetId = {};
  final Map<String, String> labelByPresetId = {};

  /// §117 задача 3: упорядоченная mirror-группа DNS-правил — по одной записи
  /// на routing-правило с активным DNS-аспектом (preset И inline/srs),
  /// в порядке обхода `custom_rules` (решение №6: порядок группы строго =
  /// порядку routing-правил).
  final List<DnsMirrorEntry> dnsMirrors = [];
}

/// §117 задача 3: один элемент mirror-группы DNS-правил.
///
/// - **preset-источник** (`presetId != null`) — `body` это одно готовое
///   DNS-правило пресета (`server` внутри, §033; у serverless-действий
///   `predefined`/`reject` его нет — §253). Пресет с несколькими правилами
///   даёт несколько entries подряд (порядок шаблона).
/// - **rule-источник** (`ruleId != null`) — `body` это DNS-безопасный матч
///   БЕЗ `server`; `serverTag` подставляется эмиссией ([applyCustomDns])
///   только если сервер дожил до финального `dns.servers` (пропавший реф —
///   тихо не эмитится, решение №3).
class DnsMirrorEntry {
  const DnsMirrorEntry({
    this.presetId,
    this.ruleId,
    this.ruleName = '',
    this.serverTag = '',
    this.serverless = false,
    this.fixedAnswer = false,
    this.blockHttps = false,
    required this.body,
  });

  final String? presetId;
  final String? ruleId;
  final String ruleName;
  final String serverTag;

  /// §256 — `body` самодостаточно (serverless-действие вроде `predefined`):
  /// эмиссия НЕ подставляет `server` и НЕ режет запись по отсутствию сервера
  /// в `dns.servers`. Для rule-источника (у preset-источника serverless-тела
  /// эмитятся по ветке `presetId != null`, §253).
  final bool serverless;

  /// §683 — serverless-тело ответа фиксированным IP (Answer = Fixed IP),
  /// а не AAAA-глушилка Force IPv4. Нужен UI вкладки DNS, чтобы различать
  /// два вида serverless-mirror'ов правила.
  final bool fixedAnswer;

  /// §755 — serverless-тело Block HTTPS/SVCB records (`query_type: [HTTPS,
  /// SVCB]`), а не Force IPv4: вкладке DNS нужно различать serverless-
  /// mirror'ы правила.
  final bool blockHttps;
  final Map<String, dynamic> body;
}

/// §683 — TTL записей ответа Fixed IP.
const int kFixedIpAnswerTtl = 300;

/// §257 — магическая var `dns_enable`: единственный тумблер DNS-блока
/// пресета (серверы + DNS-правила + mirror-группа). Семантика:
/// - пресет НЕ объявляет var → `true` (DNS всегда on, пока routing on);
/// - юзер выставил значение в varsValues → оно ('true'/'false');
/// - иначе → default_value из шаблона (пустой default → on).
///
/// Публичный: DNS Settings рисует свитч пресетной строки этим же предикатом
/// (единая точка истины билдера и UI).
bool presetDnsEnableVar(CustomRulePreset cr, SelectableRule preset) {
  WizardVar? declared;
  for (final v in preset.vars) {
    if (v.name == 'dns_enable') {
      declared = v;
      break;
    }
  }
  if (declared == null) return true;
  // §265 — если dns_enable вдруг объявлена как ref-var, её значение в
  // глобальном userVars, НЕ в varsValues. Здесь (билдер) userVars не читаем —
  // возвращаем default, чтобы не взять застрявшее varsValues-значение. Сейчас
  // dns_enable у всех пресетов — обычная var, ветка defensive.
  if (declared.isRef) return true;
  final explicit = cr.varsValues['dns_enable'];
  if (explicit != null && explicit.isNotEmpty) return explicit == 'true';
  final def = declared.defaultValue;
  return def.isEmpty || def == 'true';
}

/// §062: обработка одного preset rule. Регистрирует rule_sets через
/// `registry.tryRegisterRuleSet` (identical-skip / first-wins warning),
/// routing rule — если route-aspect enabled, DNS аспекты — если dns-aspect
/// enabled (§257: магическая var `dns_enable`). Cross-preset DNS-server
/// dedup через [state].dnsServerByTag.
List<String> _applyPresetSingle(
  CustomRulePreset cr,
  RuleSetRegistry registry,
  List<SelectableRule> presets,
  _PresetSharedState state, {
  Map<String, String> presetSrsPaths = const {},
  Map<String, String> globalVars = const {},
  List<PresetNode> presetNodes = const [],
}) {
  final warnings = <String>[];
  if (cr.presetId.isEmpty) return warnings;

  final routeEnabled = cr.enabled;
  // §121: routing-тоггл = король. Независимый DNS-флаг действует только
  // пока routing включён — выключенный пресет не порождает ни серверы, ни
  // правила, ни mirror-lock'и (как будто его нет в конфиге).
  if (!routeEnabled) return warnings;

  SelectableRule? match;
  for (final p in presets) {
    if (p.presetId == cr.presetId) {
      match = p;
      break;
    }
  }
  if (match == null) {
    warnings.add('preset "${cr.presetId}" not found in template (rule skipped)');
    return warnings;
  }

  // §257: DNS-аспект пресета гейтится магической var `dns_enable`
  // (заменила isPresetDnsEnabled из dns_options.rules — один источник
  // истины вместо двух тумблеров на один флаг). Нет var в шаблоне →
  // DNS всегда on, пока routing on (fakeip и пресеты без опционального DNS).
  final dnsEnabled = presetDnsEnableVar(cr, match);

  // Из плоской мапы `presetSrsPaths["<presetId>|<tag>"]` собираем subset
  // для текущего пресета: tag → path.
  final srsSubset = <String, String>{};
  final prefix = '${cr.presetId}|';
  for (final entry in presetSrsPaths.entries) {
    if (entry.key.startsWith(prefix)) {
      srsSubset[entry.key.substring(prefix.length)] = entry.value;
    }
  }

  final raw = expandPreset(cr, match,
      srsPaths: srsSubset, globalVars: globalVars, nodes: presetNodes);
  warnings.addAll(raw.warnings);

  // Rule sets — identical-skip / first-wins через registry.
  // Преcет может ссылаться на rule_set которые уже зарегистрировал
  // другой ранее обработанный preset (тот же presetId, identical fragment).
  for (final rs in raw.ruleSets) {
    final conflict = registry.tryRegisterRuleSet(rs);
    if (conflict) {
      final tag = rs['tag'];
      warnings.add(
          'rule_set "$tag" skipped: conflicts with earlier registered rule_set');
    }
  }

  // Routing rules — только если route-aspect активен. §246: пресет может
  // эмитить несколько правил (напр. resolve + route у ru-direct) — порядок
  // шаблона сохраняется.
  if (routeEnabled) {
    for (final r in raw.routingRules) {
      registry.addRule(r);
    }
  }

  // DNS аспекты — только если dns-aspect активен.
  if (dnsEnabled) {
    if (raw.dnsRules.isNotEmpty) {
      state.dnsRules.addAll(raw.dnsRules);
      state.dnsRulesByPresetId[cr.presetId] = raw.dnsRules;
      // §117: в mirror-группу — в позиции routing-правила (решение №6).
      // §253: по одной записи на правило, порядок шаблона сохранён — группа
      // эмитится подряд (mirror-эмиссия обходит список линейно).
      for (final r in raw.dnsRules) {
        state.dnsMirrors.add(DnsMirrorEntry(
          presetId: cr.presetId,
          ruleName: match.label,
          body: r,
        ));
      }
    }
    for (final s in raw.dnsServers) {
      final tag = s['tag'];
      if (tag is! String) {
        state.dnsServers.add(s);
        continue;
      }
      final existing = state.dnsServerByTag[tag];
      if (existing == null) {
        state.dnsServerByTag[tag] = s;
        // §578 — у пресета с `for_each_node` тег сервера без пространства пресета
        // (`<тег узла>-dns`): запись хранения DNS держит его как `ref` = тег.
        // С `preset_id` модель достроила бы тег до `tailscale:<тег>-dns`, и
        // сервер разошёлся бы с правилами, которые на него ссылаются.
        if (tag.startsWith('${cr.presetId}:')) {
          state.dnsServerPresetIdByTag[tag] = cr.presetId;
        }
        state.dnsServers.add(s);
      } else if (!const DeepCollectionEquality().equals(existing, s)) {
        warnings
            .add('dns server "$tag" skipped: conflicts with earlier preset');
      }
    }
  }

  state.labelByPresetId[cr.presetId] = match.label;
  return warnings;
}

/// Результат [applyPresetBundles] — rule-sets/routing rules уже записаны в
/// registry; DNS-фрагменты нельзя записать напрямую (они живут в другой
/// секции конфига), поэтому возвращаются вверх.
///
/// §033: `dnsRulesByPresetId` — авторитативный источник для `applyCustomDns`
/// (resolve `kind: preset` записей по immutable preset id, ТОЛЬКО для
/// preset'ов где DNS-aspect enabled). `labelByPresetId` — для UI рендера
/// title'а строки. `extraDnsRules` сохранён как legacy / debug.
class PresetApplyResult {
  final List<Map<String, dynamic>> extraDnsServers;

  /// §439 — тег сервера из [extraDnsServers] → `preset_id` его пресета.
  final Map<String, String> dnsServerPresetIdByTag;
  final List<Map<String, dynamic>> extraDnsRules;
  final Map<String, List<Map<String, dynamic>>> dnsRulesByPresetId;
  final Map<String, String> labelByPresetId;
  final List<String> warnings;

  const PresetApplyResult({
    this.extraDnsServers = const [],
    this.dnsServerPresetIdByTag = const {},
    this.extraDnsRules = const [],
    this.dnsRulesByPresetId = const {},
    this.labelByPresetId = const {},
    this.warnings = const [],
  });
}

/// Post-step: пользовательские routing-правила (spec §030; §757 — тело-дерево).
///
/// Правило [CustomRuleTree] выпускается по дереву ([_applyTreeSingle]):
/// наборы ссылок — `local` по пути из `srsPaths[<id кэша набора>]`
/// (pre-resolved caller'ом через `RuleSetDownloader`, URL в конфиг не
/// попадает), ключи `set: true` каждого простого узла — в его inline-набор,
/// остальные ключи и `invert` — на узле. Теги наборов — схема §6.13
/// ([assignRuleTags]) по всем правилам [rules].
///
/// [skipDisabled] — по умолчанию `true`: disabled-правила пропускаются как в
/// production pipeline. **Set `false` для preview-режима**, когда caller хочет
/// видеть «что родит правило при включении» независимо от Switch (e.g.
/// `ViewTab` в editor'е). Production pipeline всегда оставляет default `true`.
///
/// Рукописные теги `rule_set` здесь не сверяются с итоговым `route.rule_set`
/// (превью видит одно правило) — постпроход делает [applyAllCustomRules].
List<String> applyCustomRules(
  RuleSetRegistry registry,
  List<CustomRule> rules, {
  Map<String, String> srsPaths = const {},
  bool skipDisabled = true,
  // §683 — превью редактора: собрать и DNS-mirror'ы правила.
  List<DnsMirrorEntry>? dnsMirrors,
}) {
  final warnings = <String>[];
  final table = ruleConditionTable;
  final tags = _assignAxisTags(rules, registry.takenTags, table);
  for (final cr in rules) {
    if (skipDisabled && !cr.enabled) continue;
    switch (cr) {
      case CustomRulePreset():
        // Preset-правила обрабатывает applyPresetBundles (spec §033).
        continue;
      case CustomRuleTree():
        warnings.addAll(_applyTreeSingle(cr, tags[cr.id]!, registry, srsPaths,
                table: table, dnsMirrors: dnsMirrors)
            .warnings);
      case CustomRuleJson():
        warnings.addAll(_applyJsonSingle(cr, registry));
    }
  }
  return warnings;
}

/// §757 — теги наборов правил оси так, как их раздаёт сборка
/// ([applyAllCustomRules]): заняты [takenTags] (теги `route.rule_set`
/// шаблона) и теги наборов всех пресетов, стоящих в [rules] (включённых и
/// нет; набор, выключенный гейтом, тоже занимает свой тег). Ключ — id
/// правила. Тот же расчёт читает резолвер имён правил (список соединений).
Map<String, RuleTags> customRuleAxisTags(
  List<CustomRule> rules, {
  required Iterable<String> takenTags,
  required List<SelectableRule> presets,
  RuleConditionTable? table,
}) {
  final reserved = {
    ...takenTags,
    for (final cr in rules)
      if (cr is CustomRulePreset)
        for (final p in presets)
          if (p.presetId == cr.presetId)
            for (final rs in p.ruleSets)
              if (rs['tag'] case final String tag when tag.isNotEmpty) tag,
  };
  return _assignAxisTags(rules, reserved, table ?? ruleConditionTable);
}

/// §757 — теги наборов всех записей оси (§6.13 п. 1–5): базу берёт каждая
/// запись `inline` | `srs` (включённая и выключенная, verbatim-JSON тоже),
/// пресеты — нет. Края имени обрезает [ruleTagBase]. Ключ — id правила.
Map<String, RuleTags> _assignAxisTags(
  List<CustomRule> rules,
  Set<String> reserved,
  RuleConditionTable table,
) {
  final axis = [
    for (final r in rules)
      if (r is CustomRuleTree || r is CustomRuleJson) r,
  ];
  final assigned = assignRuleTags(
    [
      for (final r in axis)
        RuleTagInput(
          name: r.name,
          root: r is CustomRuleTree ? r.root : null,
        ),
    ],
    reserved: reserved,
    table: table,
  );
  return {for (var i = 0; i < axis.length; i++) axis[i].id: assigned[i]};
}

/// §757 — что правило-дерево зарегистрировало в реестре (постпроход
/// висячих рукописных тегов снимает это целиком).
class _TreeEmitted {
  _TreeEmitted(this.rule);

  final CustomRuleTree rule;
  final List<Map<String, dynamic>> routeRules = [];
  final Set<String> setTags = {};
  final List<String> warnings = [];
}

/// §757 — одно правило-дерево: наборы, resolve-правило (§247), маршрутное
/// правило, DNS-зеркала (§6.11). Всё или ничего: нет файла хоть одного
/// набора дерева — правило, его наборы и зеркала не выпускаются.
///
/// Пустая цель — правило не выпускается (как до §757).
_TreeEmitted _applyTreeSingle(
  CustomRuleTree cr,
  RuleTags tags,
  RuleSetRegistry registry,
  Map<String, String> srsPaths, {
  required RuleConditionTable table,
  List<DnsMirrorEntry>? dnsMirrors,
}) {
  final out = _TreeEmitted(cr);
  if (cr.outbound.isEmpty) return out;
  final res = emitRuleTree(
    ruleName: cr.name,
    body: cr.body,
    tags: tags,
    refPath: (ref) => srsPaths[CustomRuleTree.cacheIdFor(cr.id, ref)],
    table: table,
    sideInlineSets: true,
  );
  out.warnings.addAll(res.warnings);
  if (!res.emitted) return out;
  for (final rs in res.ruleSets) {
    // Теги разведены заранее (§6.13) — набор регистрируется с точным тегом.
    if (registry.tryRegisterRuleSet(rs)) {
      out.warnings.add('rule_set "${rs['tag']}" skipped: conflicts with '
          'earlier registered rule_set');
    } else {
      out.setTags.add(rs['tag'] as String);
    }
  }
  final match = res.match!;
  // §247 — нетерминальное resolve-правило ПЕРЕД терминальным (тот же матч и
  // теги); resolve-only — терминальное не выпускается (трафик проваливается
  // к следующим правилам / route.final).
  if (cr.resolveActive) {
    out.routeRules.add(registry.addRule(ruleTreeResolveRule(match, cr.resolve!)));
  }
  if (!(cr.resolveActive && cr.resolve!.only)) {
    out.routeRules.add(registry.addRule(res.routeRule!));
  }
  if (dnsMirrors != null) {
    // §6.11 — Block HTTPS → Force IPv4 → сервер либо пара Fixed IP.
    dnsMirrors.addAll(ruleTreeDnsMirrors(
      ruleId: cr.id,
      ruleName: cr.name,
      enabled: cr.enabled,
      dns: cr.dns,
      mirror: ruleTreeMirrorMatcher(match, res.inlineSets, table),
      hasRefsOrDomain: ruleTreeHasRefsOrDomain(cr.root, table),
    ).entries);
  }
  return out;
}

/// §757 — постпроход «рукописный `rule_set`» (§6.13): правило-дерево с
/// тегом, которого нет в итоговом `route.rule_set`, снимается целиком —
/// маршрутное и resolve-правило, его наборы и DNS-зеркала; предупреждение
/// называет правило и тег. Снятое правило освобождает свои наборы, поэтому
/// проход повторяется до неподвижной точки.
List<String> _dropDanglingTreeRules(
  RuleSetRegistry registry,
  List<_TreeEmitted> emitted,
  List<DnsMirrorEntry> dnsMirrors,
) {
  final warnings = <String>[];
  final live = [...emitted];
  var changed = true;
  while (changed) {
    changed = false;
    final finalTags = {
      for (final rs in registry.getRuleSets())
        if (rs['tag'] is String) rs['tag'] as String,
    };
    for (final e in [...live]) {
      if (e.routeRules.isEmpty) continue;
      final dangling = ruleTreeDanglingTags(e.rule.root, finalTags);
      if (dangling.isEmpty) continue;
      registry.removeRules(e.routeRules);
      registry.removeRuleSets(e.setTags);
      dnsMirrors.removeWhere((m) => m.ruleId == e.rule.id);
      live.remove(e);
      changed = true;
      final name = e.rule.name.trim().isEmpty ? 'unnamed' : e.rule.name.trim();
      final tags = (dangling.toList()..sort()).map((t) => '"$t"').join(', ');
      warnings.add('Rule "$name" skipped: rule_set $tags not found in the '
          'config.');
    }
  }
  return warnings;
}

/// §062: единый entry-point — обходит **все** custom rules в storage order
/// с dispatch по kind. Регистрирует rule_sets и routing rules в [registry]
/// в порядке storage, аккумулирует DNS-аспекты в [UnifiedApplyResult].
///
/// Это **исправление** артефакта старого pipeline (две группы preset →
/// inline/srs независимо), который ломал юзер-управляемый order. Storage
/// `custom_rules` это один список с mixed kind, и order этого списка
/// = order matching в sing-box.
///
/// Старые [applyPresetBundles] и [applyCustomRules] остаются как public
/// shim'ы (используются тестами), но build pipeline вызывает только этот
/// единый entry-point.
UnifiedApplyResult applyAllCustomRules(
  RuleSetRegistry registry,
  List<CustomRule> rules,
  List<SelectableRule> presets, {
  Map<String, String> srsPaths = const {},
  Map<String, String> presetSrsPaths = const {},
  Map<String, String> globalVars = const {},
  // §578 — узлы конфига для пресетов с обходом узлов (порядок конфига).
  List<PresetNode> presetNodes = const [],
}) {
  final state = _PresetSharedState();
  final warnings = <String>[];
  final table = ruleConditionTable;
  // §757 (§6.13) — теги раздаются один раз до обхода: заняты теги шаблона
  // (уже в реестре) и наборов всех пресетов, стоящих в правилах.
  final tags = customRuleAxisTags(
    rules,
    takenTags: registry.takenTags,
    presets: presets,
    table: table,
  );
  final trees = <_TreeEmitted>[];
  for (final cr in rules) {
    switch (cr) {
      case CustomRulePreset():
        // §121: routing-тоггл = король. `_applyPresetSingle` внутри сам
        // отсекает выключенный preset (cr.enabled=false) целиком (ни routing,
        // ни DNS, ни mirror), а DNS-аспект гейтит магической var `dns_enable`
        // (§257). Skip снаружи не нужен.
        warnings.addAll(_applyPresetSingle(
          cr,
          registry,
          presets,
          state,
          presetSrsPaths: presetSrsPaths,
          globalVars: globalVars,
          presetNodes: presetNodes,
        ));
      case CustomRuleTree():
        if (!cr.enabled) continue;
        final e = _applyTreeSingle(cr, tags[cr.id]!, registry, srsPaths,
            table: table, dnsMirrors: state.dnsMirrors);
        warnings.addAll(e.warnings);
        trees.add(e);
      case CustomRuleJson():
        if (!cr.enabled) continue;
        warnings.addAll(_applyJsonSingle(cr, registry));
    }
  }
  // §757 — итоговый `route.rule_set` известен только после всех правил и
  // пресетов.
  warnings.addAll(_dropDanglingTreeRules(registry, trees, state.dnsMirrors));
  return UnifiedApplyResult(
    extraDnsServers: state.dnsServers,
    dnsServerPresetIdByTag: state.dnsServerPresetIdByTag,
    extraDnsRules: state.dnsRules,
    dnsRulesByPresetId: state.dnsRulesByPresetId,
    labelByPresetId: state.labelByPresetId,
    dnsMirrors: state.dnsMirrors,
    warnings: warnings,
  );
}

/// §062: результат [applyAllCustomRules]. Same shape as [PresetApplyResult]
/// (DNS аспекты идут вверх в applyCustomDns), но семантически шире —
/// включает обработку inline/srs тоже.
///
/// §117: `dnsMirrors` — упорядоченная mirror-группа DNS-правил (порядок =
/// routing-правила); единственный источник эмиссии группы в [applyCustomDns].
class UnifiedApplyResult {
  final List<Map<String, dynamic>> extraDnsServers;

  /// §439 — тег сервера из [extraDnsServers] → `preset_id` его пресета.
  final Map<String, String> dnsServerPresetIdByTag;
  final List<Map<String, dynamic>> extraDnsRules;
  final Map<String, List<Map<String, dynamic>>> dnsRulesByPresetId;
  final Map<String, String> labelByPresetId;
  final List<DnsMirrorEntry> dnsMirrors;
  final List<String> warnings;

  const UnifiedApplyResult({
    this.extraDnsServers = const [],
    this.dnsServerPresetIdByTag = const {},
    this.extraDnsRules = const [],
    this.dnsRulesByPresetId = const {},
    this.labelByPresetId = const {},
    this.dnsMirrors = const [],
    this.warnings = const [],
  });
}

/// §225 (#17) — одно raw-JSON правило. Тело — JSON-объект `{...}` (один rule)
/// или массив объектов `[{...}, ...]` (несколько, порядок сохраняется). Битый
/// JSON / скаляр / не-Map-элемент → skip + warning (сборка не падает: правило
/// деградирует, остальной конфиг цел). Dangling `outbound` внутри тела ловит
/// `validateConfig` тем же путём, что и обычные правила.
List<String> _applyJsonSingle(CustomRuleJson cr, RuleSetRegistry registry) {
  final warnings = <String>[];
  final name = cr.name.trim().isEmpty ? 'unnamed' : cr.name.trim();
  final text = cr.json.trim();
  if (text.isEmpty) {
    warnings.add('Raw-JSON rule "$name" skipped: empty body.');
    return warnings;
  }
  final dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    warnings.add('Raw-JSON rule "$name" skipped: invalid JSON.');
    return warnings;
  }
  if (decoded is Map<String, dynamic>) {
    final dropped = _stripCommentKeys(decoded);
    if (dropped > 0) {
      warnings.add('Raw-JSON rule "$name": $dropped comment key(s) ("//...") '
          'dropped — the core rejects unknown fields.');
    }
    if (decoded.isEmpty) {
      warnings.add(
          'Raw-JSON rule "$name" skipped: empty after dropping comment keys.');
      return warnings;
    }
    registry.addRule(decoded);
  } else if (decoded is List) {
    var added = 0;
    var dropped = 0;
    for (final e in decoded) {
      if (e is Map<String, dynamic>) {
        dropped += _stripCommentKeys(e);
        // Правило целиком из комментариев → пустой объект в route.rules ядру
        // тоже не нужен (нет ни матчеров, ни action) — пропускаем.
        if (e.isEmpty) continue;
        registry.addRule(e);
        added++;
      }
    }
    if (dropped > 0) {
      warnings.add('Raw-JSON rule "$name": $dropped comment key(s) ("//...") '
          'dropped — the core rejects unknown fields.');
    }
    if (added == 0) {
      warnings.add(
          'Raw-JSON rule "$name" skipped: array has no rule objects.');
    }
  } else {
    warnings.add(
        'Raw-JSON rule "$name" skipped: expected an object or array of objects.');
  }
  return warnings;
}

/// §350 — рекурсивно снимает ключи-комментарии (`//...`) из тела raw-JSON
/// правила. sing-box strict-decode на unknown-field роняет ВЕСЬ конфиг на
/// старте, а `//`-ключ — распространённая конвенция комментариев в
/// JSON-примерах (юзер копирует пример с комментариями → fatal). Прочие
/// unknown-поля НЕ трогаем: их набор билдеру неизвестен, резать вслепую
/// опаснее, чем отдать декодеру ядра. Рекурсия по всему телу безопасна:
/// в route.rules нет free-form map'ов (все поля типизированы, вложенность —
/// только logical-`rules`), заголовков и прочих произвольных ключей там нет.
int _stripCommentKeys(Object? node) {
  var removed = 0;
  if (node is Map) {
    final bad =
        node.keys.where((k) => k is String && k.startsWith('//')).toList();
    for (final k in bad) {
      node.remove(k);
      removed++;
    }
    for (final v in node.values) {
      removed += _stripCommentKeys(v);
    }
  } else if (node is List) {
    for (final v in node) {
      removed += _stripCommentKeys(v);
    }
  }
  return removed;
}
