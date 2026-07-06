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
  Map<String, bool> isPresetDnsEnabled = const {},
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
      isPresetDnsEnabled: isPresetDnsEnabled,
    ));
  }
  return PresetApplyResult(
    extraDnsServers: state.dnsServers,
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
    required this.body,
  });

  final String? presetId;
  final String? ruleId;
  final String ruleName;
  final String serverTag;

  /// §255 — `body` самодостаточно (serverless-действие вроде `predefined`):
  /// эмиссия НЕ подставляет `server` и НЕ режет запись по отсутствию сервера
  /// в `dns.servers`. Для rule-источника (у preset-источника serverless-тела
  /// эмитятся по ветке `presetId != null`, §253).
  final bool serverless;
  final Map<String, dynamic> body;
}

/// §062: обработка одного preset rule. Регистрирует rule_sets через
/// `registry.tryRegisterRuleSet` (identical-skip / first-wins warning),
/// routing rule — если route-aspect enabled, DNS аспекты — если dns-aspect
/// enabled. Cross-preset DNS-server dedup через [state].dnsServerByTag.
List<String> _applyPresetSingle(
  CustomRulePreset cr,
  RuleSetRegistry registry,
  List<SelectableRule> presets,
  _PresetSharedState state, {
  Map<String, String> presetSrsPaths = const {},
  Map<String, bool> isPresetDnsEnabled = const {},
}) {
  final warnings = <String>[];
  if (cr.presetId.isEmpty) return warnings;

  final routeEnabled = cr.enabled;
  // §121: routing-тоггл = король. Независимый DNS-флаг (§033) действует только
  // пока routing включён — выключенный пресет не порождает ни серверы, ни
  // правила, ни mirror-lock'и (как будто его нет в конфиге).
  final dnsEnabled = routeEnabled && (isPresetDnsEnabled[cr.presetId] ?? false);
  // Routing off + DNS gated off → пресет мёртв целиком.
  if (!routeEnabled && !dnsEnabled) return warnings;

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

  // Из плоской мапы `presetSrsPaths["<presetId>|<tag>"]` собираем subset
  // для текущего пресета: tag → path.
  final srsSubset = <String, String>{};
  final prefix = '${cr.presetId}|';
  for (final entry in presetSrsPaths.entries) {
    if (entry.key.startsWith(prefix)) {
      srsSubset[entry.key.substring(prefix.length)] = entry.value;
    }
  }

  final raw = expandPreset(cr, match, srsPaths: srsSubset);
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
  final List<Map<String, dynamic>> extraDnsRules;
  final Map<String, List<Map<String, dynamic>>> dnsRulesByPresetId;
  final Map<String, String> labelByPresetId;
  final List<String> warnings;

  const PresetApplyResult({
    this.extraDnsServers = const [],
    this.extraDnsRules = const [],
    this.dnsRulesByPresetId = const {},
    this.labelByPresetId = const {},
    this.warnings = const [],
  });
}

/// Post-step: пользовательские routing-правила (spec §030).
///
/// Эмит зависит от `cr.kind`:
///
/// - `inline` — headless rule со всеми непустыми match-полями сразу. Per
///   sing-box default rule: внутри domain-family (domain/suffix/keyword/ip_cidr)
///   — OR; внутри port-family — OR; между категориями — AND. `package_name`
///   — отдельная категория (AND). `protocol` в headless rule **не
///   поддерживается**, выносим на routing-rule level.
///
/// - `srs` — **local** rule_set по пути из `srsPaths[cr.id]` (pre-resolved
///   caller'ом через `RuleSetDownloader`). Если правило srs но файла нет
///   — скипаем и пушим warning. URL в конфиг не попадает: sing-box сам
///   ничего не качает, всё managed'ится юзером через download button.
///
/// Collision handling — auto-suffix через `RuleSetRegistry`.
///
/// [skipDisabled] — по умолчанию `true`: disabled-правила пропускаются как в
/// production pipeline. **Set `false` для preview-режима**, когда caller хочет
/// видеть «что родит правило при включении» независимо от Switch (e.g.
/// `ViewTab` в editor'е — юзер открыл редактор именно для inspect'а формы,
/// `enabled` тут отдельная история). Production pipeline всегда оставляет
/// default `true`.
List<String> applyCustomRules(
  RuleSetRegistry registry,
  List<CustomRule> rules, {
  Map<String, String> srsPaths = const {},
  bool skipDisabled = true,
}) {
  // §062: shim вокруг `_applyInlineSingle` / `_applySrsSingle`. Обходит
  // ТОЛЬКО inline/srs (фильтруя preset). Сохраняет старый publi API +
  // backward-compat для тестов. Real pipeline использует [applyAllCustomRules]
  // которое обходит все kinds в одном цикле сохраняя cross-kind order.
  final warnings = <String>[];
  for (final cr in rules) {
    if (skipDisabled && !cr.enabled) continue;
    switch (cr) {
      case CustomRulePreset():
        // Preset-правила обрабатывает applyPresetBundles (spec §033).
        continue;
      case CustomRuleSrs():
        warnings.addAll(_applySrsSingle(cr, registry, srsPaths));
      case CustomRuleInline():
        warnings.addAll(_applyInlineSingle(cr, registry));
      case CustomRuleJson():
        warnings.addAll(_applyJsonSingle(cr, registry));
    }
  }
  return warnings;
}

/// §062: одно srs-правило. Skip если outbound пустой / нет cached file.
///
/// §117 задача 3: при активной DNS-опции ([CustomRule.dnsMirrorActive]) в
/// [dnsMirrors] добавляется mirror — rule_set НЕ генерится, DNS-rule
/// ссылается на тот же `.srs`-тег + DNS-безопасные доп-фильтры
/// (package_name / wifi_*; ports/protocols отрезаны гейтом).
List<String> _applySrsSingle(
  CustomRuleSrs cr,
  RuleSetRegistry registry,
  Map<String, String> srsPaths, {
  List<DnsMirrorEntry>? dnsMirrors,
}) {
  final warnings = <String>[];
  if (cr.outbound.isEmpty) return warnings;
  final requestedTag = cr.name.trim().isEmpty ? 'unnamed' : cr.name.trim();
  final path = srsPaths[cr.id];
  if (path == null) {
    warnings.add(
        'SRS rule "${cr.name}" skipped: no cached file (Download first).');
    return warnings;
  }
  final tag = registry.addRuleSet({
    'type': 'local',
    'tag': requestedTag,
    'format': 'binary',
    'path': path,
  });
  // §247 — resolve-опция: нетерминальное resolve-правило перед route (тот же
  // srs-tag и AND-фильтры). Для srs всегда eligible — домены в `.srs` возможны
  // (содержимое не парсим; IP-only лист просто не даст домена — безвредно).
  if (cr.resolveActive) {
    registry.addRule(_resolveToRoute(
      tag,
      cr.resolve!,
      ports: cr.intPorts,
      portRanges: cr.portRanges,
      packages: cr.packages,
      protocols: cr.protocols,
      ipIsPrivate: cr.ipIsPrivate,
      sourceIpCidrs: cr.sourceIpCidrs,
      sourceIpIsPrivate: cr.sourceIpIsPrivate,
      inbounds: cr.inbounds,
      wifiSsids: cr.wifiSsids,
      wifiBssids: cr.wifiBssids,
    ));
  }
  // §247 resolve-only: терминальный route не эмитится (см. inline-ветку).
  if (!(cr.resolveActive && cr.resolve!.only)) {
    registry.addRule(_outboundToRoute(
      tag,
      cr.outbound,
      ports: cr.intPorts,
      portRanges: cr.portRanges,
      packages: cr.packages,
      protocols: cr.protocols,
      ipIsPrivate: cr.ipIsPrivate,
      // §030/new_fields — у srs нет своего headless match → source/inbound
      // (вкл. source_ip_cidr) ВСЕ на routing-rule level.
      sourceIpCidrs: cr.sourceIpCidrs,
      sourceIpIsPrivate: cr.sourceIpIsPrivate,
      inbounds: cr.inbounds,
      wifiSsids: cr.wifiSsids,
      wifiBssids: cr.wifiBssids,
    ));
  }
  if (dnsMirrors != null && (cr.dnsMirrorActive || cr.forceIpv4Active)) {
    // DNS-безопасные AND-поля правила (srs: rule_set + package/wifi/source/
    // inbound — ports/protocols отрезаны гейтом). Общие для обоих mirror'ов.
    Map<String, dynamic> srsMatch() {
      final m = <String, dynamic>{'rule_set': tag};
      if (cr.packages.isNotEmpty) m['package_name'] = cr.packages;
      if (cr.wifiSsids.isNotEmpty) m['wifi_ssid'] = cr.wifiSsids;
      if (cr.wifiBssids.isNotEmpty) m['wifi_bssid'] = cr.wifiBssids;
      // §030/new_fields — DNS-rule 1.14 принимает source_ip_cidr/inbound.
      if (cr.sourceIpCidrs.isNotEmpty) m['source_ip_cidr'] = cr.sourceIpCidrs;
      if (cr.inbounds.isNotEmpty) m['inbound'] = cr.inbounds;
      return m;
    }

    // §255 — Force IPv4 (AAAA-глушилка) ПЕРЕД server-mirror'ом (симметрия §253).
    if (cr.forceIpv4Active) {
      final mirror = srsMatch()
        ..['ip_version'] = 6
        ..['action'] = 'predefined'
        ..['rcode'] = 'NOERROR';
      dnsMirrors.add(DnsMirrorEntry(
        ruleId: cr.id,
        ruleName: cr.name,
        serverless: true,
        body: mirror,
      ));
    }
    if (cr.dnsMirrorActive) {
      dnsMirrors.add(DnsMirrorEntry(
        ruleId: cr.id,
        ruleName: cr.name,
        serverTag: cr.dns!.serverTag,
        body: srsMatch(),
      ));
    }
  }
  return warnings;
}

/// §062: одно inline-правило. Headless rule_set с непустыми match-полями
/// (если они есть), плюс routing rule с routing-level полями (protocol /
/// ip_is_private / wifi_*). Если оба пусты — skip.
///
/// §117 задача 3: при активной DNS-опции ([CustomRule.dnsMirrorActive])
/// mirror шарит **тот же** headless rule_set (no split — гейт гарантирует
/// отсутствие ports/protocols в матче) + wifi_* на DNS-rule уровне.
List<String> _applyInlineSingle(
  CustomRuleInline cr,
  RuleSetRegistry registry, {
  List<DnsMirrorEntry>? dnsMirrors,
}) {
  final warnings = <String>[];
  if (cr.outbound.isEmpty) return warnings;

  // DNS-безопасные AND-поля для mirror-body (общие для server- и
  // forceIpv4-mirror'ов). rule_set несёт domain/port/wifi/source; здесь —
  // только `inbound` (route-only, в headless его нет; DNS-rule 1.14 принимает).
  Map<String, dynamic> mirrorBody(String ruleSetTag) {
    final m = <String, dynamic>{};
    if (ruleSetTag.isNotEmpty) m['rule_set'] = ruleSetTag;
    if (cr.inbounds.isNotEmpty) m['inbound'] = cr.inbounds;
    return m;
  }

  // §255 — Force IPv4 (AAAA-глушилка) эмитится ПЕРЕД server-mirror'ом
  // (симметрия §253: ip_version-гейт первым, маршрут вторым — иначе
  // server-mirror без ip_version перехватит AAAA-запрос до глушилки).
  // Serverless: `predefined` отвечает локально, server не нужен.
  void addForceIpv4Mirror(String ruleSetTag) {
    if (dnsMirrors == null || !cr.forceIpv4Active) return;
    final matchFields = mirrorBody(ruleSetTag);
    // Без матча (нет rule_set/inbound — правило только source_ip_is_private
    // и т.п.) глушилка гасила бы AAAA ГЛОБАЛЬНО. Не эмитим — нечего точечно
    // матчить на DNS-слое.
    if (matchFields.isEmpty) return;
    final mirror = matchFields
      ..['ip_version'] = 6
      ..['action'] = 'predefined'
      ..['rcode'] = 'NOERROR';
    dnsMirrors.add(DnsMirrorEntry(
      ruleId: cr.id,
      ruleName: cr.name,
      serverless: true,
      body: mirror,
    ));
  }

  void addDnsMirror(String ruleSetTag) {
    if (dnsMirrors == null || !cr.dnsMirrorActive) return;
    final mirror = mirrorBody(ruleSetTag);
    // Пустой матч (только ip_is_private/source_ip_is_private) — DNS-rule
    // «match всё» не эмитим.
    if (mirror.isEmpty) return;
    dnsMirrors.add(DnsMirrorEntry(
      ruleId: cr.id,
      ruleName: cr.name,
      serverTag: cr.dns!.serverTag,
      body: mirror,
    ));
  }
  final requestedTag = cr.name.trim().isEmpty ? 'unnamed' : cr.name.trim();
  // Inline: all non-empty match fields в один headless rule.
  final match = <String, dynamic>{};
  if (cr.domains.isNotEmpty) match['domain'] = cr.domains;
  if (cr.domainSuffixes.isNotEmpty) {
    match['domain_suffix'] = cr.domainSuffixes;
  }
  if (cr.domainKeywords.isNotEmpty) {
    match['domain_keyword'] = cr.domainKeywords;
  }
  if (cr.ipCidrs.isNotEmpty) match['ip_cidr'] = cr.ipCidrs;
  final intPorts = cr.intPorts;
  if (intPorts.isNotEmpty) match['port'] = intPorts;
  if (cr.portRanges.isNotEmpty) match['port_range'] = cr.portRanges;
  if (cr.packages.isNotEmpty) match['package_name'] = cr.packages;
  // §030/new_fields — sing-box 1.14 (`DefaultHeadlessRule`) ПРИНИМАЕТ в
  // headless: `source_ip_cidr`, `wifi_ssid`, `wifi_bssid`. Раньше (§051, под
  // 1.12) wifi выносился на routing-rule level — теперь кладём прямо в match.
  // AND с domain/port-группами внутри одного headless rule.
  if (cr.sourceIpCidrs.isNotEmpty) match['source_ip_cidr'] = cr.sourceIpCidrs;
  if (cr.wifiSsids.isNotEmpty) match['wifi_ssid'] = cr.wifiSsids;
  if (cr.wifiBssids.isNotEmpty) match['wifi_bssid'] = cr.wifiBssids;
  // `ip_is_private`, `source_ip_is_private`, `inbound`, `protocol` НЕ
  // поддерживаются в headless rule — sing-box отрежет конфиг на парсинге.
  // Выносим на routing-rule level (там OR/AND с rule_set per default-rule
  // formula).

  if (match.isEmpty) {
    // Нет полей для inline headless rule. Если есть routing-level
    // поля (protocol / ip_is_private / source_ip_is_private / inbound) —
    // эмитим routing rule без rule_set, иначе правило пустое, скипаем.
    if (cr.protocols.isEmpty &&
        !cr.ipIsPrivate &&
        !cr.sourceIpIsPrivate &&
        cr.inbounds.isEmpty) {
      return warnings;
    }
    registry.addRule(_outboundToRoute(
      '',
      cr.outbound,
      protocols: cr.protocols,
      ipIsPrivate: cr.ipIsPrivate,
      sourceIpIsPrivate: cr.sourceIpIsPrivate,
      inbounds: cr.inbounds,
    ));
    addForceIpv4Mirror(''); // §255 — AAAA-глушилка перед server-mirror'ом
    addDnsMirror(''); // routing-level-only правило: DNS-rule без rule_set
    return warnings;
  }

  final tag = registry.addRuleSet({
    'type': 'inline',
    'tag': requestedTag,
    'rules': [match],
  });
  // §247 — resolve-опция: нетерминальное resolve-правило ПЕРЕД терминальным
  // route (тот же матч/tag). Гейт resolveActive: только при непустой
  // domain-группе (чистый ip/port/proto-матч резолвить нечего).
  if (cr.resolveActive) {
    registry.addRule(_resolveToRoute(
      tag,
      cr.resolve!,
      protocols: cr.protocols,
      ipIsPrivate: cr.ipIsPrivate,
      sourceIpIsPrivate: cr.sourceIpIsPrivate,
      inbounds: cr.inbounds,
    ));
  }
  // Protocol + ip_is_private + source_ip_is_private + inbound — на routing
  // rule level (headless их не поддерживает). `ip_is_private` становится OR
  // с rule_set (per sing-box default-rule formula). source_ip_cidr/wifi_* уже
  // в headless match выше.
  //
  // §247 resolve-only: терминальное route-правило НЕ эмитится — трафик
  // проваливается к следующим правилам / route.final (осознанный advanced-
  // выбор юзера, предупреждение показано в UI; билдер не варнит).
  if (!(cr.resolveActive && cr.resolve!.only)) {
    registry.addRule(_outboundToRoute(
      tag,
      cr.outbound,
      protocols: cr.protocols,
      ipIsPrivate: cr.ipIsPrivate,
      sourceIpIsPrivate: cr.sourceIpIsPrivate,
      inbounds: cr.inbounds,
    ));
  }
  addForceIpv4Mirror(tag); // §255 — AAAA-глушилка перед server-mirror'ом
  addDnsMirror(tag);
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
  Map<String, bool> isPresetDnsEnabled = const {},
}) {
  final state = _PresetSharedState();
  final warnings = <String>[];
  for (final cr in rules) {
    switch (cr) {
      case CustomRulePreset():
        // §121: routing-тоггл = король. `_applyPresetSingle` gate'ит DNS-аспект
        // через `dnsEnabled = cr.enabled && isPresetDnsEnabled[...]`, поэтому
        // выключенный preset (cr.enabled=false) внутри сам отсекается целиком
        // (ни routing, ни DNS, ни mirror). Skip снаружи не нужен.
        warnings.addAll(_applyPresetSingle(
          cr,
          registry,
          presets,
          state,
          presetSrsPaths: presetSrsPaths,
          isPresetDnsEnabled: isPresetDnsEnabled,
        ));
      case CustomRuleInline():
        if (!cr.enabled) continue;
        warnings.addAll(
            _applyInlineSingle(cr, registry, dnsMirrors: state.dnsMirrors));
      case CustomRuleSrs():
        if (!cr.enabled) continue;
        warnings.addAll(_applySrsSingle(cr, registry, srsPaths,
            dnsMirrors: state.dnsMirrors));
      case CustomRuleJson():
        if (!cr.enabled) continue;
        warnings.addAll(_applyJsonSingle(cr, registry));
    }
  }
  return UnifiedApplyResult(
    extraDnsServers: state.dnsServers,
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
  final List<Map<String, dynamic>> extraDnsRules;
  final Map<String, List<Map<String, dynamic>>> dnsRulesByPresetId;
  final Map<String, String> labelByPresetId;
  final List<DnsMirrorEntry> dnsMirrors;
  final List<String> warnings;

  const UnifiedApplyResult({
    this.extraDnsServers = const [],
    this.extraDnsRules = const [],
    this.dnsRulesByPresetId = const {},
    this.labelByPresetId = const {},
    this.dnsMirrors = const [],
    this.warnings = const [],
  });
}

/// `outbound` (tag или `kOutboundReject`) → routing rule. Опциональные
/// AND-поля (port/port_range/packages/protocol) — для srs-режима, где эти
/// фильтры нельзя зашить в remote rule_set.
Map<String, dynamic> _outboundToRoute(
  String tag,
  String outbound, {
  List<int>? ports,
  List<String>? portRanges,
  List<String>? packages,
  List<String>? protocols,
  bool ipIsPrivate = false,
  List<String>? sourceIpCidrs,
  bool sourceIpIsPrivate = false,
  List<String>? inbounds,
  List<String>? wifiSsids,
  List<String>? wifiBssids,
}) {
  final rule = <String, dynamic>{};
  if (tag.isNotEmpty) rule['rule_set'] = tag;
  if (ports != null && ports.isNotEmpty) rule['port'] = ports;
  if (portRanges != null && portRanges.isNotEmpty) {
    rule['port_range'] = portRanges;
  }
  if (packages != null && packages.isNotEmpty) rule['package_name'] = packages;
  if (protocols != null && protocols.isNotEmpty) rule['protocol'] = protocols;
  if (ipIsPrivate) rule['ip_is_private'] = true;
  // §030/new_fields — source-IP-CIDR на routing-rule level. Для inline он
  // обычно живёт в headless match (sing-box 1.14 принимает), но для srs/
  // routing-level-fallback кладётся сюда. OR-группа источника, AND с rule_set.
  if (sourceIpCidrs != null && sourceIpCidrs.isNotEmpty) {
    rule['source_ip_cidr'] = sourceIpCidrs;
  }
  // §030/new_fields — `source_ip_is_private` / `inbound` ВСЕГДА routing-rule
  // level: headless rule_set этих полей не имеет (sing-box 1.14
  // DefaultHeadlessRule). AND с остальным правилом.
  if (sourceIpIsPrivate) rule['source_ip_is_private'] = true;
  if (inbounds != null && inbounds.isNotEmpty) rule['inbound'] = inbounds;
  // §051 — wifi_ssid / wifi_bssid эмитятся только non-empty. sing-box
  // AND-ит со всеми остальными полями rule'а; без них — fallback на любую
  // сеть (поведение pre-§051).
  //
  // ⚠ Cross-product semantic risk (low impact): sing-box обрабатывает
  // wifi_ssid и wifi_bssid как **независимые** OR-списки, AND-ясь на уровне
  // правила. Несколько chip'ов с разными BSSID-парами в editor становятся
  // `wifi_ssid:[A,B] AND wifi_bssid:[X,Y]` — теоретически matches «A на BSSID Y»
  // (не задумано юзером). На практике риск мал — BSSID = глобально уникальный
  // MAC, коллизии "правильный SSID + чужой BSSID" нереалистичны. Для exact
  // pair semantic нужно эмитить N отдельных rules (по одному chip'у),
  // решение deferred до реального use-case.
  if (wifiSsids != null && wifiSsids.isNotEmpty) rule['wifi_ssid'] = wifiSsids;
  if (wifiBssids != null && wifiBssids.isNotEmpty) {
    rule['wifi_bssid'] = wifiBssids;
  }
  if (outbound == kOutboundReject) {
    rule['action'] = 'reject';
  } else {
    rule['outbound'] = outbound;
  }
  return rule;
}

/// §247 — нетерминальное resolve-правило (route rule action `resolve`,
/// sing-box 1.14). Тот же матч, что у парного route-правила (переиспользует
/// [_outboundToRoute] для всей AND-механики match-полей), но вместо
/// outbound/reject — `action: resolve` + непустые опции [RuleResolve].
/// Эмитится ПЕРЕД терминальным route (или вместо него при `only`).
Map<String, dynamic> _resolveToRoute(
  String tag,
  RuleResolve r, {
  List<int>? ports,
  List<String>? portRanges,
  List<String>? packages,
  List<String>? protocols,
  bool ipIsPrivate = false,
  List<String>? sourceIpCidrs,
  bool sourceIpIsPrivate = false,
  List<String>? inbounds,
  List<String>? wifiSsids,
  List<String>? wifiBssids,
}) {
  final rule = _outboundToRoute(
    tag,
    '',
    ports: ports,
    portRanges: portRanges,
    packages: packages,
    protocols: protocols,
    ipIsPrivate: ipIsPrivate,
    sourceIpCidrs: sourceIpCidrs,
    sourceIpIsPrivate: sourceIpIsPrivate,
    inbounds: inbounds,
    wifiSsids: wifiSsids,
    wifiBssids: wifiBssids,
  );
  rule.remove('outbound');
  rule['action'] = 'resolve';
  // Пустое/null поле = ключ не эмитится (дефолты ядра: strategy наследует
  // dns.strategy, server — DNS-роутинг).
  if (r.strategy.isNotEmpty) rule['strategy'] = r.strategy;
  if (r.serverTag.isNotEmpty) rule['server'] = r.serverTag;
  if (r.disableCache) rule['disable_cache'] = true;
  if (r.disableOptimisticCache) rule['disable_optimistic_cache'] = true;
  if (r.rewriteTtl != null) rule['rewrite_ttl'] = r.rewriteTtl;
  if (r.timeout.isNotEmpty) rule['timeout'] = r.timeout;
  if (r.clientSubnet.isNotEmpty) rule['client_subnet'] = r.clientSubnet;
  return rule;
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
    registry.addRule(decoded);
  } else if (decoded is List) {
    var added = 0;
    for (final e in decoded) {
      if (e is Map<String, dynamic>) {
        registry.addRule(e);
        added++;
      }
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
