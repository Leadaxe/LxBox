import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';

import '../../models/custom_rule.dart';
import '../../models/parser_config.dart';
import '../settings_storage.dart' show SettingsStorage, TunAppsConfig;
import 'preset_expand.dart';
import 'rule_set_registry.dart';

/// Post-step: рандомизация регистра букв в `server_name` first-hop outbound'ов
/// (§028 spec). Mixed-case SNI ломает exact-match DPI без изменения поведения
/// сервера (RFC 6066 §3 — SNI case-insensitive). First-hop only — inner hops
/// в туннеле, локальный DPI их не видит. Punycode-метки (`xn--…`) не трогаем —
/// `xn--` префикс зарезервирован, регистр в Punycode-payload sensitive.
///
/// Выполняется на этапе emit конфига; зафиксировано на жизнь туннеля.
/// Re-randomization на каждый handshake потребовала бы патча libbox.
void applyMixedCaseSni(Map<String, dynamic> config, Map<String, String> vars) {
  if (vars['tls_mixed_case_sni'] != 'true') return;
  final rng = Random.secure();
  final outbounds = config['outbounds'] as List<dynamic>? ?? const [];
  for (final ob in outbounds) {
    if (ob is! Map<String, dynamic>) continue;
    if (ob.containsKey('detour')) continue;
    final tls = ob['tls'];
    if (tls is! Map<String, dynamic>) continue;
    final sn = tls['server_name'];
    if (sn is! String || sn.isEmpty) continue;
    tls['server_name'] = _randomizeHostCase(sn, rng);
  }
}

String _randomizeHostCase(String host, Random rng) {
  // Идём по DNS-меткам (split по '.'). xn--… — Punycode, не трогаем.
  final labels = host.split('.');
  for (var i = 0; i < labels.length; i++) {
    final label = labels[i];
    if (label.startsWith('xn--')) continue;
    final buf = StringBuffer();
    for (final cu in label.codeUnits) {
      // ASCII letter? рандомим. Всё остальное (цифры, дефис, не-ASCII) — как есть.
      final isUpper = cu >= 0x41 && cu <= 0x5A;
      final isLower = cu >= 0x61 && cu <= 0x7A;
      if (isUpper || isLower) {
        buf.writeCharCode(rng.nextBool() ? (cu | 0x20) : (cu & ~0x20));
      } else {
        buf.writeCharCode(cu);
      }
    }
    labels[i] = buf.toString();
  }
  return labels.join('.');
}

/// Post-step: применение tls_fragment к first-hop'ам (без `detour`).
/// Inner hops уже в туннеле, DPI не видит их TLS — фрагментация не нужна.
void applyTlsFragment(Map<String, dynamic> config, Map<String, String> vars) {
  final fragment = vars['tls_fragment'] == 'true';
  final recordFragment = vars['tls_record_fragment'] == 'true';
  if (!fragment && !recordFragment) return;

  final fallbackDelay = vars['tls_fragment_fallback_delay'] ?? '500ms';
  final outbounds = config['outbounds'] as List<dynamic>? ?? const [];
  for (final ob in outbounds) {
    if (ob is! Map<String, dynamic>) continue;
    if (ob.containsKey('detour')) continue;
    final tls = ob['tls'];
    if (tls is! Map<String, dynamic>) continue;
    if (tls['enabled'] != true) continue;
    if (fragment) tls['fragment'] = true;
    if (recordFragment) tls['record_fragment'] = true;
    tls['fragment_fallback_delay'] = fallbackDelay;
  }
}

/// Post-step: §046 — OS-level split-tunneling. Подставляет `include_package`
/// или `exclude_package` в `inbound[type=tun]` на основе `tun_apps` storage.
///
/// Mode → sing-box config:
/// - `off`        → ничего не пишем (sing-box default = все apps через tun)
/// - `allow`      → `tun.include_package = packages` (только эти через tun)
/// - `deny`       → `tun.exclude_package = packages` (все КРОМЕ этих)
///
/// libbox потом читает эти поля из config и передаёт в native слой
/// (BoxVpnService.kt:557-560), который зовёт `VpnService.Builder
/// .addAllowedApplication`/`.addDisallowedApplication`. Применяется на
/// `builder.establish()` — нужен FULL VPN restart, light reload не работает.
///
/// Если `mode != off` но `packages` пустой — silently no-op (нечего apply'ить).
/// Если в config нет tun-inbound — silently no-op (некуда apply'ить).
void applyTunPackages(Map<String, dynamic> config, TunAppsConfig tunApps) {
  if (tunApps.isOff || tunApps.packages.isEmpty) return;

  final inbounds = config['inbounds'];
  if (inbounds is! List) return;

  Map<String, dynamic>? tun;
  for (final i in inbounds) {
    if (i is Map<String, dynamic> && i['type'] == 'tun') {
      tun = i;
      break;
    }
  }
  if (tun == null) return;

  final field = tunApps.isAllow ? 'include_package' : 'exclude_package';
  tun[field] = List<String>.from(tunApps.packages);
}

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
/// **Rules (§041 + §032 + §033):** структурированный список
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
/// Legacy записи (§032 shape: `kind: user`, `kind: rule`, `title` вместо `name`)
/// silently dropped — старые ключи не распознаются, auto-discovery восстанавливает
/// fresh state.
Future<void> applyCustomDns(
  Map<String, dynamic> config,
  Map<String, dynamic> templateDnsOptions, {
  List<Map<String, dynamic>> extraServers = const [],
  Map<String, Map<String, dynamic>> extraDnsRulesByPresetId = const {},
  Set<String> activePresetIdsWithDnsRule = const {},
  Map<String, String> dnsSrsCachedPaths = const {},
}) async {
  final dns = (config['dns'] as Map<String, dynamic>?) ?? <String, dynamic>{};

  // §043: resolve dns servers через kind-discriminated refs (симметрия с
  // §041 DNS rules). Builder получает только final bodies через resolver;
  // storage хранит refs `{enabled, kind, tag, body?}`.
  final templateServers =
      (templateDnsOptions['servers'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
  final templateByTag = <String, Map<String, dynamic>>{
    for (final s in templateServers)
      if (s['tag'] is String && (s['tag'] as String).isNotEmpty)
        s['tag'] as String: s,
  };
  final presetServersByTag = <String, Map<String, dynamic>>{
    for (final s in extraServers)
      if (s['tag'] is String && (s['tag'] as String).isNotEmpty)
        s['tag'] as String: Map<String, dynamic>.from(s),
  };

  // Auto-discover + orphan cleanup + legacy migration.
  final resolvedServers = await resolveDnsServersList(
    templateServers: templateServers,
    presetServersByTag: presetServersByTag,
  );

  // Refs → final bodies для sing-box config.
  dns['servers'] = resolveDnsServersBodies(
    resolved: resolvedServers,
    templateByTag: templateByTag,
    presetServersByTag: presetServersByTag,
  );

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

  for (final entry in resolved) {
    if (entry['enabled'] != true) continue;
    final kind = entry['kind'] as String?;
    if (kind == null) continue;
    if (kind == 'inline') {
      final body = entry['rule'];
      if (body is Map<String, dynamic>) outRules.add(body);
    } else if (kind == 'template') {
      final name = entry['name'] as String?;
      if (name == null || name.isEmpty) continue;
      final t = templateRulesByName[name];
      if (t != null) {
        final clean = Map<String, dynamic>.from(t)
          ..remove('name')
          ..remove('enabled_default');
        outRules.add(clean);
      }
    } else if (kind == 'preset') {
      final pid = entry['presetId'] as String?;
      if (pid == null || pid.isEmpty) continue;
      final body = extraDnsRulesByPresetId[pid];
      if (body != null) outRules.add(body);
    } else if (kind == 'srs') {
      final id = entry['id'] as String?;
      final name = entry['name'] as String?;
      final server = entry['server'] as String?;
      if (id == null || id.isEmpty) continue;
      if (server == null || server.isEmpty) continue;
      final path = dnsSrsCachedPaths[id];
      if (path == null) continue; // no cache → skip silently
      final tag = (name != null && name.isNotEmpty) ? name : 'dns_srs_$id';
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
      final extra = entry['rule'];
      if (extra is Map<String, dynamic>) {
        for (final e in extra.entries) {
          if (e.key == 'rule_set' || e.key == 'server') continue;
          dnsRule[e.key] = e.value;
        }
      }
      outRules.add(dnsRule);
    }
    // unknown kind (e.g. legacy 'user', 'rule') — silently dropped
  }
  if (outRules.isNotEmpty) dns['rules'] = outRules;
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

/// §041 + §033: разрешает текущий список DNS-правил из storage.
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
/// **Legacy ignore (§033):** старые `kind: user`, `kind: rule`, поле `title`
/// (вместо `name`) — silently dropped (не распознаются → не попадают в result).
/// Auto-discovery восстанавливает fresh state.
///
/// Используется и `applyCustomDns` (build pipeline), и `DnsSettingsScreen`
/// (UI load) — единая точка истины.
Future<List<Map<String, dynamic>>> resolveDnsRulesList({
  required List<Map<String, dynamic>> templateRules,
  required Set<String> activePresetIdsWithDnsRule,
}) async {
  final stored = await SettingsStorage.getDnsRulesList();

  final templateNames = <String>{
    for (final r in templateRules)
      if (r['name'] is String && (r['name'] as String).isNotEmpty)
        r['name'] as String,
  };

  final result = <Map<String, dynamic>>[];
  final seenTemplateNames = <String>{};
  final seenPresetIds = <String>{};

  for (final raw in stored) {
    final entry = Map<String, dynamic>.from(raw);
    final kind = entry['kind'] as String?;
    if (kind == null) continue;

    if (kind == 'inline') {
      final name = entry['name'] as String?;
      if (name == null || name.isEmpty) continue;
      result.add(entry);
    } else if (kind == 'srs') {
      final id = entry['id'] as String?;
      final name = entry['name'] as String?;
      if (id == null || id.isEmpty) continue;
      if (name == null || name.isEmpty) continue;
      // SRS-записи всегда сохраняются (cached file проверяется на build,
      // не здесь). UI пока не показывает их edit/delete.
      result.add(entry);
    } else if (kind == 'template') {
      final name = entry['name'] as String?;
      if (name == null || name.isEmpty) continue;
      if (templateNames.contains(name)) {
        result.add(entry);
        seenTemplateNames.add(name);
      }
    } else if (kind == 'preset') {
      final pid = entry['presetId'] as String?;
      if (pid == null || pid.isEmpty) continue;
      // Mandatory link (§033): запись сохраняется только если есть
      // соответствующий active custom_rules.kind:preset И preset имеет
      // dns_rule в шаблоне.
      if (activePresetIdsWithDnsRule.contains(pid)) {
        result.add(entry);
        seenPresetIds.add(pid);
      }
    }
    // Все остальные kind'ы (legacy 'user', 'rule', неизвестные) — silently dropped
  }

  // §041 default order: inline (user) → preset → template.
  // Auto-discovery вставляет новые preset DNS rules ПЕРЕД первой
  // template-записью (чтобы preset имел приоритет в матчинге); новые
  // template-defaults — append в конец (lowest priority).
  //
  // Stored entries сохраняют свой пользовательский порядок (юзер мог
  // перетащить через drag-handle); auto-discovery затрагивает только
  // НОВЫЕ записи.
  int templateBlockStart = result.length;
  for (var i = 0; i < result.length; i++) {
    if (result[i]['kind'] == 'template') {
      templateBlockStart = i;
      break;
    }
  }

  // Auto-discover недостающие preset DNS rules — вставляем перед template-блоком.
  // §033 auto-link: для каждого active custom_rules.kind:preset (имеющего
  // dns_rule в шаблоне) создаём соответствующую `kind: preset` запись в
  // dns_options.rules с enabled=true.
  for (final pid in activePresetIdsWithDnsRule) {
    if (seenPresetIds.contains(pid)) continue;
    result.insert(templateBlockStart, {
      'enabled': true,
      'kind': 'preset',
      'presetId': pid,
    });
    templateBlockStart++;
  }

  // Auto-discover недостающие template-defaults — append в конец
  for (final r in templateRules) {
    final name = r['name'];
    if (name is! String || name.isEmpty) continue;
    if (seenTemplateNames.contains(name)) continue;
    final enabledDefault = r['enabled_default'] != false;
    result.add({
      'enabled': enabledDefault,
      'kind': 'template',
      'name': name,
    });
  }

  // Persist если изменилось.
  if (!_dnsRulesListEqual(stored, result)) {
    await SettingsStorage.saveDnsRulesList(result);
  }
  return result;
}

bool _dnsRulesListEqual(
  List<Map<String, dynamic>> a,
  List<Map<String, dynamic>> b,
) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (jsonEncode(a[i]) != jsonEncode(b[i])) return false;
  }
  return true;
}

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
  final warnings = <String>[];
  final fragmentsList = <PresetFragments>[];
  // §033: map presetId → expanded dns_rule (только если DNS-aspect enabled).
  // applyCustomDns использует это для resolve `kind: preset` записей в
  // `dns_options.rules` по immutable preset id.
  final dnsRulesByPresetId = <String, Map<String, dynamic>>{};
  // Lookup helper: presetId → label для UI рендера.
  final labelByPresetId = <String, String>{};

  for (final cr in rules) {
    if (cr is! CustomRulePreset) continue;
    if (cr.presetId.isEmpty) continue;

    final routeEnabled = cr.enabled;
    final dnsEnabled = isPresetDnsEnabled[cr.presetId] ?? false;
    // §033: expand если хотя бы одна сторона активна.
    if (!routeEnabled && !dnsEnabled) continue;

    SelectableRule? match;
    for (final p in presets) {
      if (p.presetId == cr.presetId) {
        match = p;
        break;
      }
    }
    if (match == null) {
      warnings.add('preset "${cr.presetId}" not found in template (rule skipped)');
      continue;
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

    // §033: per-aspect фильтр — гасим routingRule если route-side выключен,
    // dnsRule + dnsServers если DNS-side выключен. ruleSets оставляем всегда:
    // на них могут ссылаться обе стороны, и dedup делает mergeFragments.
    final filtered = PresetFragments(
      ruleSets: raw.ruleSets,
      routingRule: routeEnabled ? raw.routingRule : null,
      dnsRule: dnsEnabled ? raw.dnsRule : null,
      dnsServers: dnsEnabled ? raw.dnsServers : const [],
      warnings: raw.warnings,
    );

    fragmentsList.add(filtered);
    if (filtered.dnsRule != null) {
      dnsRulesByPresetId[cr.presetId] = filtered.dnsRule!;
    }
    labelByPresetId[cr.presetId] = match.label;
  }

  final merged = mergeFragments(fragmentsList);
  warnings.addAll(merged.warnings);

  for (final rs in merged.ruleSets) {
    final conflict = registry.tryRegisterRuleSet(rs);
    if (conflict) {
      final tag = rs['tag'];
      warnings.add('rule_set "$tag" skipped: conflicts with earlier registered rule_set');
    }
  }
  for (final r in merged.routingRules) {
    registry.addRule(r);
  }

  return PresetApplyResult(
    extraDnsServers: merged.dnsServers,
    extraDnsRules: merged.dnsRules,
    dnsRulesByPresetId: dnsRulesByPresetId,
    labelByPresetId: labelByPresetId,
    warnings: warnings,
  );
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
  final Map<String, Map<String, dynamic>> dnsRulesByPresetId;
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
List<String> applyCustomRules(
  RuleSetRegistry registry,
  List<CustomRule> rules, {
  Map<String, String> srsPaths = const {},
}) {
  final warnings = <String>[];
  for (final cr in rules) {
    if (!cr.enabled) continue;
    switch (cr) {
      case CustomRulePreset():
        // Preset-правила обрабатывает applyPresetBundles (spec §033).
        continue;
      case CustomRuleSrs():
        if (cr.outbound.isEmpty) continue;
        final requestedTag =
            cr.name.trim().isEmpty ? 'unnamed' : cr.name.trim();
        final path = srsPaths[cr.id];
        if (path == null) {
          warnings.add(
              'SRS rule "${cr.name}" skipped: no cached file (Download first).');
          continue;
        }
        final tag = registry.addRuleSet({
          'type': 'local',
          'tag': requestedTag,
          'format': 'binary',
          'path': path,
        });
        registry.addRule(_outboundToRoute(
          tag,
          cr.outbound,
          ports: cr.intPorts,
          portRanges: cr.portRanges,
          packages: cr.packages,
          protocols: cr.protocols,
          ipIsPrivate: cr.ipIsPrivate,
          wifiSsids: cr.wifiSsids,
          wifiBssids: cr.wifiBssids,
        ));
      case CustomRuleInline():
        if (cr.outbound.isEmpty) continue;
        final requestedTag =
            cr.name.trim().isEmpty ? 'unnamed' : cr.name.trim();
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
        // `ip_is_private`, `wifi_ssid`, `wifi_bssid` НЕ поддерживаются в
        // headless rule — sing-box отрежет конфиг на парсинге. Выносим на
        // routing-rule level (там OR с rule_set per default-rule formula).

        if (match.isEmpty) {
          // Нет полей для inline headless rule. Если есть routing-level
          // поля (protocol / ip_is_private / wifi_*) — эмитим routing rule
          // без rule_set, иначе правило пустое, скипаем.
          if (cr.protocols.isEmpty &&
              !cr.ipIsPrivate &&
              cr.wifiSsids.isEmpty &&
              cr.wifiBssids.isEmpty) {
            continue;
          }
          registry.addRule(_outboundToRoute(
            '',
            cr.outbound,
            protocols: cr.protocols,
            ipIsPrivate: cr.ipIsPrivate,
            wifiSsids: cr.wifiSsids,
            wifiBssids: cr.wifiBssids,
          ));
          continue;
        }

        final tag = registry.addRuleSet({
          'type': 'inline',
          'tag': requestedTag,
          'rules': [match],
        });
        // Protocol + ip_is_private + wifi_* — на routing rule level (headless
        // их не поддерживает). `ip_is_private` становится OR с rule_set (per
        // sing-box default-rule formula) — это ровно то что юзер ожидает.
        // Wifi-условия AND-ятся: фильтруют match на конкретный wifi network.
        registry.addRule(_outboundToRoute(
          tag,
          cr.outbound,
          protocols: cr.protocols,
          ipIsPrivate: cr.ipIsPrivate,
          wifiSsids: cr.wifiSsids,
          wifiBssids: cr.wifiBssids,
        ));
    }
  }
  return warnings;
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
  // §051 — wifi_ssid / wifi_bssid эмитятся только non-empty. sing-box
  // AND-ит со всеми остальными полями rule'а; без них — fallback на любую
  // сеть (поведение pre-§051).
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

// ===========================================================================
// §043: DNS servers — refs by kind (симметрия с §041 DNS rules)
// ===========================================================================

/// §043: Auto-discovery + orphan cleanup + legacy migration для
/// `dns_options.servers`. Возвращает список ref-записей шейпа
/// `{enabled, kind: inline|preset|template, tag, body?}` (body только для inline).
///
/// Используется и UI (DnsSettingsScreen) и build-time pipeline'ом — единая
/// точка истины. Persist'ит в storage если результат отличается от raw'а.
///
/// **Resolve order — user → preset → template:**
/// - Walk stored entries; orphan-cleanup'им template/preset entries чьи tag'и
///   не существуют в текущем template / active preset'ах. Inline keep всегда.
/// - Auto-discovery: для каждого preset/template-server'а tag которого нет
///   в storage — append'им новую entry со значением `enabled` из template'а
///   (для template) либо `true` (для preset).
///
/// **Migration с v1.6.0** (legacy full-body snapshot list):
/// - Если каждая запись имеет поле `kind` — already migrated, no-op.
/// - Иначе — каждая запись классифицируется:
///   - tag не в template и не в preset → `kind: inline` с full body (pure user).
///   - tag в template/preset, shape совпадает (modulo `enabled`/`description`)
///     → `kind: template/preset` ref (без body).
///   - tag в template/preset, shape отличается → `kind: inline` с full body
///     (real override).
Future<List<Map<String, dynamic>>> resolveDnsServersList({
  required List<Map<String, dynamic>> templateServers,
  required Map<String, Map<String, dynamic>> presetServersByTag,
}) async {
  final raw = await SettingsStorage.getDnsServers();
  final templateByTag = <String, Map<String, dynamic>>{
    for (final s in templateServers)
      if (s['tag'] is String && (s['tag'] as String).isNotEmpty)
        s['tag'] as String: s,
  };

  // Step 1: legacy migration (full-body snapshot → kind-refs).
  final stored = _migrateLegacyDnsServers(raw, templateByTag, presetServersByTag);

  // Step 2: filter / orphan-cleanup, preserving user order.
  final result = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final raw in stored) {
    final entry = Map<String, dynamic>.from(raw);
    final kind = entry['kind'] as String?;
    final tag = entry['tag']?.toString();
    if (kind == null || tag == null || tag.isEmpty) continue;
    if (seen.contains(tag)) continue;
    if (kind == 'inline') {
      if (entry['body'] is! Map) continue; // malformed
      result.add(entry);
      seen.add(tag);
    } else if (kind == 'template') {
      if (!templateByTag.containsKey(tag)) continue; // orphan
      result.add(entry);
      seen.add(tag);
    } else if (kind == 'preset') {
      if (!presetServersByTag.containsKey(tag)) continue; // orphan
      result.add(entry);
      seen.add(tag);
    }
    // Other kinds (legacy, unknown) — silently dropped, auto-discovery восстановит
  }

  // Step 3: auto-discover missing preset entries (preset > template priority).
  for (final tag in presetServersByTag.keys) {
    if (seen.contains(tag)) continue;
    result.add({'enabled': true, 'kind': 'preset', 'tag': tag});
    seen.add(tag);
  }
  // Step 4: auto-discover missing template entries (наследуют enabled из template).
  for (final s in templateServers) {
    final tag = s['tag']?.toString();
    if (tag == null || tag.isEmpty) continue;
    if (seen.contains(tag)) continue;
    final enabled = s['enabled'] != false;
    result.add({'enabled': enabled, 'kind': 'template', 'tag': tag});
    seen.add(tag);
  }

  // Step 5: persist if changed (deep-equality чтобы не писать на каждый load).
  if (!const DeepCollectionEquality().equals(raw, result)) {
    await SettingsStorage.saveDnsServers(result);
  }
  return result;
}

/// §044: Migration helper. Приводит storage-entries к §044 schema:
/// `{kind, enabled, tag, description?, body?}` где body — partial sing-box
/// shape БЕЗ полей `tag`/`description`/`enabled`.
///
/// Поддерживает три исходных state'а (auto-detect):
/// - **pre-§043** (legacy full-body snapshot, нет поля `kind`):
///   classify by canonical match → конвертируем в kind-ref;
///   для inline — peel `description` на ref-level, body partial.
/// - **§043 inline с полями tag/description/enabled внутри body**:
///   peel `description` → ref-level; drop body's `tag`/`description`/`enabled`.
/// - **§043 template/preset ref / уже §044**:
///   no-op (уже корректная форма).
///
/// Lossless: user data не теряется. Persist'ит только если что-то изменилось
/// (см. caller).
List<Map<String, dynamic>> _migrateLegacyDnsServers(
  List<Map<String, dynamic>> raw,
  Map<String, Map<String, dynamic>> templateByTag,
  Map<String, Map<String, dynamic>> presetServersByTag,
) {
  if (raw.isEmpty) return raw;

  final out = <Map<String, dynamic>>[];
  for (final s in raw) {
    final tag = s['tag']?.toString();
    if (tag == null || tag.isEmpty) continue;
    final kind = s['kind']?.toString();

    if (kind == null) {
      // pre-§043: classify by canonical match
      final tpl = templateByTag[tag];
      final preset = presetServersByTag[tag];
      final canonical = preset ?? tpl; // preset > template
      final canonicalKind =
          preset != null ? 'preset' : (tpl != null ? 'template' : null);
      final enabled = s['enabled'] != false;
      if (canonical == null) {
        // Pure custom — kind: inline с peeled description + partial body
        out.add(_makeInlineRef(s, tag, enabled));
      } else if (_serverShapesMatch(s, canonical)) {
        // Snapshot canonical — kind ref без body
        out.add({'enabled': enabled, 'kind': canonicalKind!, 'tag': tag});
      } else {
        // Real override — kind: inline
        out.add(_makeInlineRef(s, tag, enabled));
      }
    } else if (kind == 'inline') {
      // Уже kind-ref. Проверяем — если body содержит tag/description/enabled
      // (это § 043 shape), peel'им их.
      final bodyRaw = s['body'];
      final body =
          bodyRaw is Map ? Map<String, dynamic>.from(bodyRaw) : <String, dynamic>{};
      final needsPeel = body.containsKey('tag') ||
          body.containsKey('description') ||
          body.containsKey('enabled');
      if (needsPeel) {
        final ref = <String, dynamic>{
          'enabled': s['enabled'] != false,
          'kind': 'inline',
          'tag': tag,
        };
        // Peel description на ref-level (§044 хранит здесь).
        // Если на ref'е уже есть description — не перезаписываем (user-set takes precedence).
        final descFromBody = body['description']?.toString();
        final descOnRef = s['description']?.toString();
        if (descOnRef != null && descOnRef.isNotEmpty) {
          ref['description'] = descOnRef;
        } else if (descFromBody != null && descFromBody.isNotEmpty) {
          ref['description'] = descFromBody;
        }
        // Strip body fields, что live на ref'е.
        body.remove('tag');
        body.remove('description');
        body.remove('enabled');
        // Strip UI annotations если протекли.
        body.remove('_origin');
        body.remove('_overrides');
        body.remove('_preset_label');
        ref['body'] = body;
        out.add(ref);
      } else {
        // Already §044 shape — просто пропускаем как есть.
        out.add(s);
      }
    } else {
      // kind: template / preset / другое — без изменений.
      out.add(s);
    }
  }
  return out;
}

/// Создаёт §044 inline ref из pre-§043 full-body snapshot'а:
/// peel description на ref-level, body partial без tag/description/enabled.
Map<String, dynamic> _makeInlineRef(
    Map<String, dynamic> snapshot, String tag, bool enabled) {
  final ref = <String, dynamic>{
    'enabled': enabled,
    'kind': 'inline',
    'tag': tag,
  };
  final desc = snapshot['description']?.toString();
  if (desc != null && desc.isNotEmpty) {
    ref['description'] = desc;
  }
  final body = Map<String, dynamic>.from(snapshot)
    ..remove('tag')
    ..remove('description')
    ..remove('enabled')
    ..remove('_origin')
    ..remove('_overrides')
    ..remove('_preset_label');
  ref['body'] = body;
  return ref;
}

/// Deep-equality по server shape (без mutable meta + UI-аннотаций).
/// Order-insensitive — для сравнения pre-§043 snapshot'а с canonical.
bool _serverShapesMatch(Map<String, dynamic> a, Map<String, dynamic> b) {
  return const DeepCollectionEquality()
      .equals(_stripMetaForCompare(a), _stripMetaForCompare(b));
}

Map<String, dynamic> _stripMetaForCompare(Map<String, dynamic> m) {
  final out = Map<String, dynamic>.from(m);
  out.remove('enabled');
  out.remove('description');
  out.remove('_origin');
  out.remove('_overrides');
  out.remove('_preset_label');
  return out;
}

/// §043 + §044: Resolves ref-list в final list of sing-box server bodies для
/// `config.dns.servers`.
///
/// Source резолва:
/// - `kind: inline` → `entry.body` (partial, без tag/description/enabled — §044).
/// - `kind: template` → lookup `templateByTag[entry.tag]` (full canonical).
/// - `kind: preset` → lookup `presetServersByTag[entry.tag]`.
///
/// Synthesis (запротоколированная магия §044):
/// - `body['tag'] = entry.tag` — single source of truth, инжект из ref'а.
/// - Strip `description` / `enabled` (sing-box их не использует) из body
///   независимо от source'а.
/// - Filter `enabled != false` на уровне ref'а (вычитаем disabled-серверы).
List<Map<String, dynamic>> resolveDnsServersBodies({
  required List<Map<String, dynamic>> resolved,
  required Map<String, Map<String, dynamic>> templateByTag,
  required Map<String, Map<String, dynamic>> presetServersByTag,
}) {
  final out = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final entry in resolved) {
    if (entry['enabled'] == false) continue;
    final kind = entry['kind'] as String?;
    final tag = entry['tag']?.toString();
    if (kind == null || tag == null || tag.isEmpty) continue;
    if (seen.contains(tag)) continue;
    Map<String, dynamic>? body;
    if (kind == 'inline') {
      final b = entry['body'];
      if (b is Map) body = Map<String, dynamic>.from(b);
    } else if (kind == 'template') {
      final t = templateByTag[tag];
      if (t != null) body = Map<String, dynamic>.from(t);
    } else if (kind == 'preset') {
      final p = presetServersByTag[tag];
      if (p != null) body = Map<String, dynamic>.from(p);
    }
    if (body == null) continue;
    body
      ..remove('enabled')
      ..remove('description')
      ..remove('_preset_label')
      ..remove('_origin')
      ..remove('_overrides');
    body['tag'] = tag; // ensure tag set (даже если body lost его при edit'е)
    out.add(body);
    seen.add(tag);
  }
  return out;
}
