import 'dart:convert';
import 'dart:math';

import '../../models/custom_rule.dart';
import '../../models/parser_config.dart';
import '../settings_storage.dart' show SettingsStorage;
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

/// Post-step: наполнение `config.dns`. В шаблоне `dns_options.servers`
/// (плюс override от пользователя в SettingsStorage). Шаблон использует
/// имена серверов (`cloudflare_udp`, `google_doh`) в `route.default_domain_resolver`
/// — если секция dns пустая, sing-box падает на старте.
///
/// Очищаем wizard-only поля (`enabled`, `description`) перед записью.
///
/// `extraServers` / `extraRules` приходят от bundle-пресетов (spec §033) —
/// их инжектируем в финальный `config.dns`:
///   - servers: template first, bundle after (bundle = "опциональные
///     дополнения", template = baseline; resolver-ссылки в шаблоне всегда
///     указывают на template-теги)
///   - rules: bundle **перед** template (bundle rules должны матчить до
///     fallback-правила `{server: google_doh}`). Игнорируются если юзер
///     сделал полный user-override через `setDnsRules` — честная
///     передача ответственности.
Future<void> applyCustomDns(
  Map<String, dynamic> config,
  Map<String, dynamic> templateDnsOptions, {
  List<Map<String, dynamic>> extraServers = const [],
  List<Map<String, dynamic>> extraRules = const [],
}) async {
  final userServers = await SettingsStorage.getDnsServers();
  final userRulesJson = await SettingsStorage.getDnsRules();

  final dns = (config['dns'] as Map<String, dynamic>?) ?? <String, dynamic>{};

  final sourceServers = userServers.isNotEmpty
      ? userServers
      : (templateDnsOptions['servers'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  final servers = <Map<String, dynamic>>[];
  final seenTags = <String>{};
  for (final s in sourceServers) {
    if (s['enabled'] == false) continue;
    final clean = Map<String, dynamic>.from(s)
      ..remove('enabled')
      ..remove('description');
    final tag = clean['tag'];
    if (tag is String) seenTags.add(tag);
    servers.add(clean);
  }
  for (final s in extraServers) {
    final clean = Map<String, dynamic>.from(s)
      ..remove('enabled')
      ..remove('description');
    final tag = clean['tag'];
    if (tag is String && !seenTags.add(tag)) continue; // deduplicate
    servers.add(clean);
  }
  dns['servers'] = servers;

  if (userRulesJson.isNotEmpty) {
    try {
      final rules = jsonDecode(userRulesJson);
      if (rules is List) dns['rules'] = rules;
    } catch (_) {}
  } else {
    final tr = templateDnsOptions['rules'] as List<dynamic>?;
    final merged = <Map<String, dynamic>>[
      ...extraRules,
      if (tr != null)
        ...tr.whereType<Map<String, dynamic>>(),
    ];
    if (merged.isNotEmpty) dns['rules'] = merged;
  }

  config['dns'] = dns;
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
}) {
  final warnings = <String>[];
  final fragmentsList = <PresetFragments>[];

  for (final cr in rules) {
    if (!cr.enabled) continue;
    if (cr is! CustomRulePreset) continue;
    if (cr.presetId.isEmpty) continue;

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

    fragmentsList.add(expandPreset(cr, match, srsPaths: srsSubset));
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
    warnings: warnings,
  );
}

/// Результат [applyPresetBundles] — rule-sets/routing rules уже записаны в
/// registry; DNS-фрагменты нельзя записать напрямую (они живут в другой
/// секции конфига), поэтому возвращаются вверх.
class PresetApplyResult {
  final List<Map<String, dynamic>> extraDnsServers;
  final List<Map<String, dynamic>> extraDnsRules;
  final List<String> warnings;

  const PresetApplyResult({
    this.extraDnsServers = const [],
    this.extraDnsRules = const [],
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
        // `ip_is_private` НЕ поддерживается в headless rule — sing-box
        // отрежет конфиг на парсинге. Выносим на routing-rule level
        // (там OR с rule_set per default-rule formula).

        if (match.isEmpty) {
          // Нет полей для inline headless rule. Если есть routing-level
          // поля (protocol / ip_is_private) — эмитим routing rule без
          // rule_set, иначе правило пустое, скипаем.
          if (cr.protocols.isEmpty && !cr.ipIsPrivate) continue;
          registry.addRule(_outboundToRoute(
            '',
            cr.outbound,
            protocols: cr.protocols,
            ipIsPrivate: cr.ipIsPrivate,
          ));
          continue;
        }

        final tag = registry.addRuleSet({
          'type': 'inline',
          'tag': requestedTag,
          'rules': [match],
        });
        // Protocol + ip_is_private — на routing rule level (headless их не
        // поддерживает). `ip_is_private` становится OR с rule_set (per
        // sing-box default-rule formula) — это ровно то что юзер ожидает.
        registry.addRule(_outboundToRoute(
          tag,
          cr.outbound,
          protocols: cr.protocols,
          ipIsPrivate: cr.ipIsPrivate,
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
  if (outbound == kOutboundReject) {
    rule['action'] = 'reject';
  } else {
    rule['outbound'] = outbound;
  }
  return rule;
}
