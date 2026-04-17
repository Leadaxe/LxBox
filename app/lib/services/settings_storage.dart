import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/proxy_source.dart';

/// Persistent storage for user settings: vars, proxy sources, enabled rules.
class SettingsStorage {
  SettingsStorage._();

  static const _fileName = 'lxbox_settings.json';
  static Map<String, dynamic>? _cache;

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<Map<String, dynamic>> _load() async {
    if (_cache != null) return _cache!;
    try {
      final f = await _file();
      if (await f.exists()) {
        final raw = await f.readAsString();
        _cache = jsonDecode(raw) as Map<String, dynamic>;
        return _cache!;
      }
    } catch (_) {}
    _cache = {};
    return _cache!;
  }

  static Future<void> _save() async {
    // Clean up removed keys
    _cache?.remove('node_overrides');
    final f = await _file();
    await f.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_cache ?? {}),
    );
  }

  // ---------------------------------------------------------------------------
  // Vars
  // ---------------------------------------------------------------------------

  static Future<String> getVar(String name, String defaultValue) async {
    final data = await _load();
    final vars = data['vars'] as Map<String, dynamic>? ?? {};
    return vars[name]?.toString() ?? defaultValue;
  }

  static Future<void> setVar(String name, String value) async {
    final data = await _load();
    final vars = (data['vars'] as Map<String, dynamic>?) ?? {};
    vars[name] = value;
    data['vars'] = vars;
    _cache = data;
    await _save();
  }

  static Future<Map<String, String>> getAllVars() async {
    final data = await _load();
    final vars = data['vars'] as Map<String, dynamic>? ?? {};
    return vars.map((k, v) => MapEntry(k, v.toString()));
  }

  // ---------------------------------------------------------------------------
  // Proxy sources
  // ---------------------------------------------------------------------------

  static Future<List<ProxySource>> getProxySources() async {
    final data = await _load();
    final list = data['proxy_sources'] as List<dynamic>? ?? [];
    return list
        .map((e) => ProxySource.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> saveProxySources(List<ProxySource> sources) async {
    final data = await _load();
    data['proxy_sources'] = sources.map((e) => e.toJson()).toList();
    _cache = data;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // Enabled selectable rules
  // ---------------------------------------------------------------------------

  static Future<Set<String>> getEnabledRules() async {
    final data = await _load();
    final list = data['enabled_rules'] as List<dynamic>? ?? [];
    return list.map((e) => e.toString()).toSet();
  }

  static Future<void> saveEnabledRules(Set<String> rules) async {
    final data = await _load();
    data['enabled_rules'] = rules.toList();
    _cache = data;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // Enabled preset groups
  // ---------------------------------------------------------------------------

  static Future<Set<String>> getEnabledGroups() async {
    final data = await _load();
    final list = data['enabled_groups'] as List<dynamic>? ?? [];
    return list.map((e) => e.toString()).toSet();
  }

  static Future<void> saveEnabledGroups(Set<String> groups) async {
    final data = await _load();
    data['enabled_groups'] = groups.toList();
    _cache = data;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // Last global update timestamp
  // ---------------------------------------------------------------------------

  static Future<DateTime?> getLastGlobalUpdate() async {
    final data = await _load();
    final raw = data['last_global_update'] as String?;
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  static Future<void> setLastGlobalUpdate(DateTime dt) async {
    final data = await _load();
    data['last_global_update'] = dt.toIso8601String();
    _cache = data;
    await _save();
  }

  /// Parses a Go-style duration string like "4h", "12h", "30m" into a [Duration].
  static Duration? parseReloadInterval(String reload) {
    final trimmed = reload.trim().toLowerCase();
    if (trimmed.isEmpty) return null;
    final match = RegExp(r'^(\d+)\s*(h|m|s)$').firstMatch(trimmed);
    if (match == null) return null;
    final value = int.parse(match.group(1)!);
    return switch (match.group(2)) {
      'h' => Duration(hours: value),
      'm' => Duration(minutes: value),
      's' => Duration(seconds: value),
      _ => null,
    };
  }

  /// Returns true if subscriptions should be refreshed based on the reload interval.
  static Future<bool> shouldRefreshSubscriptions(String reloadInterval) async {
    final interval = parseReloadInterval(reloadInterval);
    if (interval == null) return false;
    final lastUpdate = await getLastGlobalUpdate();
    if (lastUpdate == null) return true;
    return DateTime.now().difference(lastUpdate) >= interval;
  }

  /// Clears the in-memory cache (useful for tests).
  static void clearCache() => _cache = null;

  // ---------------------------------------------------------------------------
  // Rule outbounds: Map<ruleLabel, outboundTag>
  // ---------------------------------------------------------------------------

  static Future<Map<String, String>> getRuleOutbounds() async {
    final data = await _load();
    final map = data['rule_outbounds'] as Map<String, dynamic>? ?? {};
    return map.map((k, v) => MapEntry(k, v.toString()));
  }

  static Future<void> saveRuleOutbounds(Map<String, String> outbounds) async {
    final data = await _load();
    data['rule_outbounds'] = outbounds;
    _cache = data;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // App routing rules (per-app outbound)
  // ---------------------------------------------------------------------------

  static Future<List<AppRule>> getAppRules() async {
    final data = await _load();
    final list = data['app_rules'] as List<dynamic>? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(AppRule.fromJson)
        .toList();
  }

  static Future<void> saveAppRules(List<AppRule> rules) async {
    final data = await _load();
    data['app_rules'] = rules.map((r) => r.toJson()).toList();
    _cache = data;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // Route final outbound
  // ---------------------------------------------------------------------------

  static Future<String> getRouteFinal() async {
    final data = await _load();
    return (data['route_final'] as String?) ?? '';
  }

  static Future<void> saveRouteFinal(String outbound) async {
    final data = await _load();
    data['route_final'] = outbound;
    _cache = data;
    await _save();
  }

  static Future<Set<String>> getExcludedNodes() async {
    final data = await _load();
    final list = data['excluded_nodes'] as List<dynamic>?;
    if (list == null) return {};
    return list.map((e) => e.toString()).toSet();
  }

  static Future<void> saveExcludedNodes(Set<String> excluded) async {
    final data = await _load();
    data['excluded_nodes'] = excluded.toList();
    _cache = data;
    await _save();
  }

  static Future<List<Map<String, dynamic>>> getDnsServers() async {
    final data = await _load();
    final dns = data['dns_options'] as Map<String, dynamic>?;
    if (dns == null) return [];
    final servers = dns['servers'] as List<dynamic>?;
    if (servers == null) return [];
    return servers.whereType<Map<String, dynamic>>().toList();
  }

  static Future<void> saveDnsServers(List<Map<String, dynamic>> servers) async {
    final data = await _load();
    final dns = (data['dns_options'] as Map<String, dynamic>?) ?? {};
    dns['servers'] = servers;
    data['dns_options'] = dns;
    _cache = data;
    await _save();
  }

  static Future<String> getDnsRules() async {
    final data = await _load();
    final dns = data['dns_options'] as Map<String, dynamic>?;
    if (dns == null) return '';
    return dns['rules_json'] as String? ?? '';
  }

  static Future<void> saveDnsRules(String rulesJson) async {
    final data = await _load();
    final dns = (data['dns_options'] as Map<String, dynamic>?) ?? {};
    dns['rules_json'] = rulesJson;
    data['dns_options'] = dns;
    _cache = data;
    await _save();
  }
}

/// A per-app routing rule: a named group of packages with an outbound.
class AppRule {
  AppRule({required this.name, this.packages = const [], this.outbound = 'direct-out'});

  String name;
  List<String> packages;
  String outbound;

  factory AppRule.fromJson(Map<String, dynamic> json) => AppRule(
        name: json['name'] as String? ?? '',
        packages: (json['packages'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        outbound: json['outbound'] as String? ?? 'direct-out',
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'packages': packages,
        'outbound': outbound,
      };
}
