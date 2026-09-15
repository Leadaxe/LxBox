part of '../post_steps.dart';

/// Post-step: наполнение `config.dns`. В шаблоне `dns_options.servers`
/// (плюс override от пользователя в SettingsStorage). Шаблон использует
/// имена серверов (`cloudflare_udp`, `google_doh`) в `route.default_domain_resolver`
/// — если секция dns пустая, sing-box падает на старте.
///
/// Очищаем wizard-only поля (`enabled`, `description`) перед записью.
///
/// **Servers (без изменений):** `extraServers` от bundle-пресетов
/// дедуплицируются с template/user серверами по `tag`.
///
/// **Rules (§061 + §032 + §033):** структурированный список
/// `dns_options.rules` в storage — `{enabled, kind, name?, presetId?,
/// srsUrl?, id?, server?, rule?}`. Унифицированный kind set с `custom_rules`:
///
///   - `kind: inline`   — `name` (freeform) + `rule` body inline (sing-box DNS-rule shape)
///   - `kind: srs`      — `name` + `id` + `srsUrl` + `server` (DNS-server tag);
///                        builder резолвит cached path по id, регистрирует
///                        `rule_set: {type: local, path}` и эмитит DNS-rule
///                        `{rule_set: <tag>, server: <server>}`. UI пока
///                        не редактируется — model only.
///   - `kind: preset`   — `presetId` (== `selectable_rule.preset_id`).
///                        Independent enable от `custom_rules.kind:preset`
///                        с тем же presetId. varsValues live в custom_rules.
///   - `kind: template` — `name` (== `template.dnsOptions.rules[i].name`).
///                        DNS-only (для route'инга template-defaults нет).
///
/// Body для `kind: template` берётся из `templateDnsOptions.rules`,
/// для `kind: preset` — из `extraDnsRulesByPresetId[presetId]` (заполняется
/// `applyPresetBundles` только если DNS-aspect enabled).
///
/// Перед сборкой делаем `resolveDnsRulesList` — auto-discovery недостающих
/// записей + orphan cleanup. Изменённый список сохраняется в storage сразу.
///
/// §439 A1 — записи, которые модель не выражает (в том числе формы §032:
/// `kind: user`, `kind: rule`), до сборки не доходят и в хранении остаются.
Future<void> applyCustomDns(
  Map<String, dynamic> config,
  Map<String, dynamic> templateDnsOptions, {
  List<Map<String, dynamic>> extraServers = const [],
  // §439 — тег сервера из [extraServers] → `preset_id` его пресета.
  Map<String, String> extraServerPresetIds = const {},
  Map<String, List<Map<String, dynamic>>> extraDnsRulesByPresetId = const {},
  Set<String> activePresetIdsWithDnsRule = const {},
  Map<String, String> dnsSrsCachedPaths = const {},
  List<DnsMirrorEntry> dnsMirrors = const [],
  List<String>? warningsOut, // §312 — дропы членов DNS-групп → emitWarnings
  // §435 — DNS-записи узлов (NODE_SECTIONS.md §3 п. 4) после подстановки
  // `@self`: серверы — тела с `tag`, в конец `dns.servers`; правила — тела,
  // в конец `dns.rules`. `enabled: false` отсеян вызывающим.
  List<Map<String, dynamic>> nodeServers = const [],
  List<Map<String, dynamic>> nodeRules = const [],
  // §441/§443 (SPEC 129 Н10) — умолчания шаблона; вторая линия читает
  // `dns_default_domain_resolver` — замену резолверов на сервер, выпавший из-за
  // висячего detour ([healDetourDroppedDnsRefs]). `dns.final` на такой сервер
  // не заменяется, а снимается с заглушкой `reject`.
  Map<String, String> resolverDefaults = const {},
}) async {
  final dns = (config['dns'] as Map<String, dynamic>?) ?? <String, dynamic>{};

  // §043: resolve dns servers через kind-discriminated refs (симметрия с
  // §061 DNS rules, бывший feature §041). Builder получает только final bodies через resolver;
  // storage хранит refs `{enabled, kind, tag, body?}`.
  final templateServers =
      (templateDnsOptions['servers'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
  // §117: template-серверы — обёртки `{description, enabled, vars?, server}`.
  final templateByTag = templateDnsServersByTag(templateServers);
  final presetServersByTag = <String, Map<String, dynamic>>{
    for (final s in extraServers)
      if (s['tag'] is String && (s['tag'] as String).isNotEmpty)
        s['tag'] as String: Map<String, dynamic>.from(s),
  };

  // Auto-discover + orphan cleanup + legacy migration.
  final resolvedServers = await resolveDnsServersList(
    templateServers: templateServers,
    presetServersByTag: presetServersByTag,
    presetIdByTag: extraServerPresetIds,
  );

  // §117: known outbound-теги (outbounds + endpoints уже в конфиге на этом
  // шаге пайплайна) — для зачистки dangling `detour` у DNS-серверов.
  final knownOutboundTags = <String>{
    for (final o in (config['outbounds'] as List<dynamic>? ?? const []))
      if (o is Map && o['tag'] is String) o['tag'] as String,
    for (final e in (config['endpoints'] as List<dynamic>? ?? const []))
      if (e is Map && e['tag'] is String) e['tag'] as String,
  };
  // §435 — цели `endpoint` DNS-сервера `tailscale`: только эмитированные
  // endpoint'ы этого типа (узел, снятый гейтом ядра, сюда не попал).
  final tailscaleEndpointTags = <String>{
    for (final e in (config['endpoints'] as List<dynamic>? ?? const []))
      if (e is Map && e['type'] == 'tailscale' && e['tag'] is String)
        e['tag'] as String,
  };

  // §117 задача 3: серверы, реферимые активными правилами (rule-источники
  // mirror-группы) — force-include в dns.servers (lifecycle, locked №7).
  final ruleReferencedTags = <String>{
    for (final m in dnsMirrors)
      if (m.ruleId != null && m.serverTag.isNotEmpty) m.serverTag,
  };

  // Refs → final bodies для sing-box config.
  // §441 — теги серверов, выпавших из-за висячего detour (Н10).
  final detourDropped = <String>{};
  final serverBodies = resolveDnsServersBodies(
    resolved: resolvedServers,
    templateByTag: templateByTag,
    presetServersByTag: presetServersByTag,
    knownOutboundTags: knownOutboundTags,
    ruleReferencedTags: ruleReferencedTags,
    warningsOut: warningsOut,
    nodeServers: nodeServers, // §435
    tailscaleEndpointTags: tailscaleEndpointTags, // §435
    detourDroppedOut: detourDropped, // §441
  );
  dns['servers'] = serverBodies;

  // §117: реально эмитированные серверы — фильтр mirror'ов с пропавшим
  // serverTag (тихо, без warning — решение №3).
  //
  // §441 (Н10) — сервер, выпавший из-за висячего detour, не «пропал»: правила
  // на него остаются и становятся отказом ([healDetourDroppedDnsRefs]), иначе
  // их домены ушли бы в `dns.final`.
  final emittedServerTags = <String>{
    for (final s in serverBodies)
      if (s['tag'] is String) s['tag'] as String,
    ...detourDropped,
  };

  // §033: resolve DNS rules — auto-discover + orphan cleanup + persist
  final templateRules = (templateDnsOptions['rules'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  final resolved = await resolveDnsRulesList(
    templateRules: templateRules,
    activePresetIdsWithDnsRule: activePresetIdsWithDnsRule,
  );
  final templateRulesByName = <String, Map<String, dynamic>>{
    for (final r in templateRules)
      if (r['name'] is String && (r['name'] as String).isNotEmpty)
        r['name'] as String: r,
  };

  final outRules = <Map<String, dynamic>>[];
  // Дополнительные rule_set'ы из kind: srs DNS-правил (registered как local).
  // Возвращаем наружу через config — caller должен мерджить в route.rule_set.
  final extraDnsSrsRuleSets = <Map<String, dynamic>>[];

  // §117 (решение №6): mirror-группа эмитится один раз, атомарно, в порядке
  // routing-правил. Якорь — первая kind:preset запись §061-списка; без
  // preset-якоря — перед template-блоком; совсем без якоря — в конец.
  var mirrorGroupEmitted = false;
  void emitMirrorGroup() {
    if (mirrorGroupEmitted) return;
    mirrorGroupEmitted = true;
    for (final m in dnsMirrors) {
      if (m.presetId != null) {
        // Preset-источник: body несёт server (serverless-действия §253 —
        // predefined/reject — без него, эмитятся как есть). Defensive:
        // dangling server (преcет-сервер не дожил до dns.servers) → тихо
        // пропускаем.
        final srv = m.body['server'];
        if (srv is String && !emittedServerTags.contains(srv)) continue;
        outRules.add(m.body);
      } else if (m.serverless) {
        // §256 — Rule-источник, serverless (Force IPv4 predefined): тело
        // самодостаточно, server не подставляем и не режем по его отсутствию.
        outRules.add(m.body);
      } else {
        // Rule-источник: пропавший сервер → DNS-rule тихо не эмитится
        // (решение №3).
        if (!emittedServerTags.contains(m.serverTag)) continue;
        outRules.add({...m.body, 'server': m.serverTag});
      }
    }
  }

  for (final entry in resolved) {
    if (entry is DnsRulePreset) {
      if (dnsMirrors.isNotEmpty) {
        // §117: запись — позиционный якорь группы; тела preset-правил живут
        // в mirror-группе (порядок routing-правил), per-preset тумблер уже
        // учтён при её сборке (§257: магическая var dns_enable; поле
        // `enabled` этой записи — мёртвое, билдер его не читает).
        emitMirrorGroup();
        continue;
      }
      // Legacy-ветка (вызовы без dnsMirrors — shim'ы/старые тесты):
      // позиционная эмиссия тел по записи, как до §117 (§253: правил
      // может быть несколько — порядок шаблона).
      if (!entry.enabled) continue;
      final bodies = extraDnsRulesByPresetId[entry.presetId];
      if (bodies != null) outRules.addAll(bodies);
      continue;
    }
    if (entry is DnsRuleTemplate &&
        dnsMirrors.isNotEmpty &&
        !mirrorGroupEmitted) {
      emitMirrorGroup(); // нет preset-якоря → группа перед template-блоком
    }
    if (!entry.enabled) continue;
    switch (entry) {
      case DnsRuleInline(:final rule):
        outRules.add(rule);
      case DnsRuleTemplate(:final name):
        final t = templateRulesByName[name];
        if (t != null) {
          final clean = Map<String, dynamic>.from(t)
            ..remove('name')
            ..remove('enabled_default');
          outRules.add(clean);
        }
      case DnsRuleSrs(
          :final id,
          :final name,
          :final body,
          server: final legacyServer,
          rule: final legacyRule,
        ):
        // §439 A1 — `server` и доп. условия: форма §033 (ключи верхнего
        // уровня) раньше `body` §294. До A1 сборка читала только форму §033,
        // и srs-правило формы §294 в конфиг не попадало.
        final bodyServer = body?['server'];
        final server =
            legacyServer ?? (bodyServer is String ? bodyServer : null);
        final rule = legacyRule ?? body;
        if (server == null || server.isEmpty) continue;
        final path = dnsSrsCachedPaths[id];
        if (path == null) continue; // no cache → skip silently
        final tag = name.isNotEmpty ? name : 'dns_srs_$id';
        extraDnsSrsRuleSets.add({
          'type': 'local',
          'tag': tag,
          'format': 'binary',
          'path': path,
        });
        final dnsRule = <String, dynamic>{
          'rule_set': tag,
          'server': server,
        };
        // Optional extra fields from rule body (e.g., extra match conditions)
        if (rule != null) {
          for (final e in rule.entries) {
            if (e.key == 'rule_set' || e.key == 'server') continue;
            dnsRule[e.key] = e.value;
          }
        }
        outRules.add(dnsRule);
      case DnsRulePreset():
        break; // обработан выше
    }
  }
  // §117: якоря не нашлось (нет preset/template записей) → группа в конец.
  if (dnsMirrors.isNotEmpty) emitMirrorGroup();
  // §435 — DNS-правила узлов в конец, после пользовательских и mirror-группы
  // (NODE_SECTIONS.md §3 п. 4). Правило на сервер, который не доехал до
  // `dns.servers` (висячий `endpoint`, дубль тега, гейт ядра), выбрасывается:
  // DNS-правило без действующего `server` ядро отвергает. Правила только с
  // `action` живут.
  for (final r in nodeRules) {
    final srv = r['server'];
    if (srv is String && srv.isNotEmpty && !emittedServerTags.contains(srv)) {
      warningsOut?.add(
          'Node DNS rule dropped: its server "$srv" is not in dns.servers.');
      continue;
    }
    outRules.add(Map<String, dynamic>.of(r));
  }
  if (outRules.isNotEmpty) dns['rules'] = outRules;
  config['dns'] = dns;
  // §441/§443 (SPEC 129 Н10) — правила, `dns.final` и резолверы на серверы,
  // выпавшие из-за висячего detour: одно место политики.
  warningsOut?.addAll(healDetourDroppedDnsRefs(
    config,
    detourDropped: detourDropped,
    defaults: resolverDefaults,
  ));
  if (extraDnsSrsRuleSets.isNotEmpty) {
    // Подмешиваем в route.rule_set (sing-box рекомендует rule_set'ы держать
    // в одном месте). DNS-rule ссылается на этот tag по имени.
    final route = (config['route'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final existing = (route['rule_set'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        <Map<String, dynamic>>[];
    final knownTags = <String>{
      for (final rs in existing)
        if (rs['tag'] is String) rs['tag'] as String,
    };
    for (final rs in extraDnsSrsRuleSets) {
      final tag = rs['tag'];
      if (tag is String && knownTags.add(tag)) {
        existing.add(rs);
      }
    }
    route['rule_set'] = existing;
    config['route'] = route;
  }

  config['dns'] = dns;
}

/// §061 + §033: разрешает текущий список DNS-правил из storage.
///
/// Делает три вещи в одном проходе:
/// 1. **Orphan cleanup:** записи `kind: template/preset` чьи identifiers больше
///    не существуют в текущем шаблоне / активных custom_rules.kind:preset —
///    выбрасываются. `kind: inline/srs` всегда сохраняются.
/// 2. **Auto-discovery:** template-правила и `kind: preset` записи для
///    активных custom_rules.kind:preset (с dns_rule в шаблоне) которые
///    появились/обнаружились впервые — добавляются (preset перед template-
///    блоком, template — в конец).
/// 3. **Persist:** если результат отличается от storage — сохраняем сразу.
///
/// §439 A1 — записи, которые модель не выражает (незнакомый вид, формы §032),
/// сюда не приходят и сохранением не стираются: их держит репозиторий.
///
/// Используется и `applyCustomDns` (build pipeline), и `DnsSettingsScreen`
/// (UI load) — единая точка истины.
Future<List<DnsRuleRef>> resolveDnsRulesList({
  required List<Map<String, dynamic>> templateRules,
  required Set<String> activePresetIdsWithDnsRule,
}) async {
  final stored = await SettingsStorage.getDnsRulesList();

  final templateNames = <String>{
    for (final r in templateRules)
      if (r['name'] is String && (r['name'] as String).isNotEmpty)
        r['name'] as String,
  };

  final result = <DnsRuleRef>[];
  final seenTemplateNames = <String>{};
  final seenPresetIds = <String>{};

  for (final entry in stored) {
    switch (entry) {
      // SRS-записи всегда сохраняются (cached file проверяется на build,
      // не здесь).
      case DnsRuleInline() || DnsRuleSrs():
        result.add(entry);
      case DnsRuleTemplate(:final name):
        if (templateNames.contains(name)) {
          result.add(entry);
          seenTemplateNames.add(name);
        }
      case DnsRulePreset(:final presetId):
        // Mandatory link (§033): запись сохраняется только если есть
        // соответствующий active custom_rules.kind:preset И preset имеет
        // dns_rule в шаблоне.
        if (activePresetIdsWithDnsRule.contains(presetId)) {
          result.add(entry);
          seenPresetIds.add(presetId);
        }
    }
  }

  // §061 default order: inline (user) → preset → template.
  // Auto-discovery вставляет новые preset DNS rules ПЕРЕД первой
  // template-записью (чтобы preset имел приоритет в матчинге); новые
  // template-defaults — append в конец (lowest priority).
  //
  // Stored entries сохраняют свой пользовательский порядок (юзер мог
  // перетащить через drag-handle); auto-discovery затрагивает только
  // НОВЫЕ записи.
  var templateBlockStart = result.indexWhere((e) => e is DnsRuleTemplate);
  if (templateBlockStart < 0) templateBlockStart = result.length;

  // Auto-discover недостающие preset DNS rules — вставляем перед template-блоком.
  // §033 auto-link: для каждого active custom_rules.kind:preset (имеющего
  // dns_rule в шаблоне) создаём соответствующую `kind: preset` запись в
  // dns_options.rules с enabled=true.
  for (final pid in activePresetIdsWithDnsRule) {
    if (seenPresetIds.contains(pid)) continue;
    result.insert(
        templateBlockStart, DnsRulePreset(presetId: pid, enabled: true));
    templateBlockStart++;
  }

  // Auto-discover недостающие template-defaults — append в конец
  for (final r in templateRules) {
    final name = r['name'];
    if (name is! String || name.isEmpty) continue;
    if (seenTemplateNames.contains(name)) continue;
    final enabledDefault = r['enabled_default'] != false;
    result.add(DnsRuleTemplate(name: name, enabled: enabledDefault));
  }

  // §117 (решение №6): kind:preset записи — часть атомарной mirror-группы;
  // держим их соседними (компакция к позиции первой). Standalone-правила
  // могут стоять только выше или ниже группы целиком, не внутри.
  final firstPresetIdx = result.indexWhere((e) => e is DnsRulePreset);
  if (firstPresetIdx >= 0) {
    final presetBlock =
        result.whereType<DnsRulePreset>().toList(growable: false);
    if (presetBlock.length > 1) {
      result.removeWhere((e) => e is DnsRulePreset);
      result.insertAll(firstPresetIdx, presetBlock);
    }
  }

  // Persist если изменилось.
  if (!const ListEquality<DnsRuleRef>().equals(stored, result)) {
    await SettingsStorage.saveDnsRulesList(result);
  }
  return result;
}
