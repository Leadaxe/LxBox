import 'dart:convert';
import 'dart:math';

import '../../models/parser_config.dart';
import '../settings_storage.dart' show AppRule, SettingsStorage;

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

/// Post-step: selectable rules (rule_set + rules).
void applySelectableRules(
  Map<String, dynamic> config,
  List<SelectableRule> allRules,
  Set<String> enabledLabels,
  Map<String, String> ruleOutbounds,
  Set<String> enabledGroups,
) {
  final route = config['route'] as Map<String, dynamic>? ?? {};
  final ruleSets = route['rule_set'] as List<dynamic>? ?? [];
  final rules = route['rules'] as List<dynamic>? ?? [];

  for (final sr in allRules) {
    final enabled = enabledLabels.contains(sr.label) ||
        (enabledLabels.isEmpty && sr.defaultEnabled);
    if (!enabled) continue;

    for (final rs in sr.ruleSets) {
      final tag = rs['tag'];
      if (tag != null && !ruleSets.any((e) => e is Map && e['tag'] == tag)) {
        ruleSets.add(rs);
      }
    }
    if (sr.rule.isNotEmpty) {
      final userOut = ruleOutbounds[sr.label];
      final ruleToAdd = (userOut != null &&
              userOut.isNotEmpty &&
              sr.rule.containsKey('outbound'))
          ? {...sr.rule, 'outbound': userOut}
          : sr.rule;
      if (ruleToAdd.isNotEmpty) rules.add(ruleToAdd);
    }
  }

  route['rule_set'] = ruleSets;
  route['rules'] = rules;
  config['route'] = route;
}

/// Post-step: наполнение `config.dns`. В шаблоне `dns_options.servers`
/// (плюс override от пользователя в SettingsStorage). Шаблон использует
/// имена серверов (`cloudflare_udp`, `google_doh`) в `route.default_domain_resolver`
/// — если секция dns пустая, sing-box падает на старте.
///
/// Очищаем wizard-only поля (`enabled`, `description`) перед записью.
Future<void> applyCustomDns(
    Map<String, dynamic> config, Map<String, dynamic> templateDnsOptions) async {
  final userServers = await SettingsStorage.getDnsServers();
  final userRulesJson = await SettingsStorage.getDnsRules();

  final dns = (config['dns'] as Map<String, dynamic>?) ?? <String, dynamic>{};

  final sourceServers = userServers.isNotEmpty
      ? userServers
      : (templateDnsOptions['servers'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  final servers = <Map<String, dynamic>>[];
  for (final s in sourceServers) {
    if (s['enabled'] == false) continue;
    final clean = Map<String, dynamic>.from(s)
      ..remove('enabled')
      ..remove('description');
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
    if (tr != null) dns['rules'] = tr;
  }

  config['dns'] = dns;
}

/// Post-step: per-app routing rules.
void applyAppRules(Map<String, dynamic> config, List<AppRule> appRules) {
  if (appRules.isEmpty) return;
  final route = config['route'] as Map<String, dynamic>? ?? {};
  final rules = route['rules'] as List<dynamic>? ?? [];
  for (final ar in appRules) {
    if (ar.packages.isEmpty || ar.outbound.isEmpty) continue;
    rules.add({'package_name': ar.packages, 'outbound': ar.outbound});
  }
  route['rules'] = rules;
  config['route'] = route;
}
