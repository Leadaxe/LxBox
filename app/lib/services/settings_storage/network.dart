part of '../settings_storage.dart';

// Route final / excluded nodes / DNS servers+rules / ping-options для
// [SettingsStorage].
//
// Вынесено `part`'ом — та же библиотека, тот же доступ к `_load`/`_save`/
// `_cache`. Семантика storage-ключей идентична исходнику.

// ---------------------------------------------------------------------------
// Route final outbound
// ---------------------------------------------------------------------------

Future<String> _getRouteFinal() async {
  final data = await _load();
  return (data['route_final'] as String?) ?? '';
}

Future<void> _saveRouteFinal(String outbound) async {
  final data = await _load();
  data['route_final'] = outbound;
  SettingsStorage._cache = data;
  await _save();
}

Future<Set<String>> _getExcludedNodes() async {
  final data = await _load();
  final list = data['excluded_nodes'] as List<dynamic>?;
  if (list == null) return {};
  return list.map((e) => e.toString()).toSet();
}

Future<void> _saveExcludedNodes(Set<String> excluded) async {
  final data = await _load();
  data['excluded_nodes'] = excluded.toList();
  SettingsStorage._cache = data;
  await _save();
}

Future<List<Map<String, dynamic>>> _getDnsServers() async {
  final data = await _load();
  final dns = data['dns_options'] as Map<String, dynamic>?;
  if (dns == null) return [];
  final servers = dns['servers'] as List<dynamic>?;
  if (servers == null) return [];
  return servers.whereType<Map<String, dynamic>>().toList();
}

Future<void> _saveDnsServers(List<Map<String, dynamic>> servers) async {
  final data = await _load();
  final dns = (data['dns_options'] as Map<String, dynamic>?) ?? {};
  dns['servers'] = servers;
  data['dns_options'] = dns;
  SettingsStorage._cache = data;
  await _save();
}

// ---------------------------------------------------------------------------
// Ping/test options (§040)
//
// Storage shape mirrors template `ping_options.{url, timeout_ms, presets}`,
// плюс расширение `groups: Map<groupTag, {url?, timeout_ms?}>` — per-group
// override'ы для ping/mass-ping/URLTest. Resolve chain в HomeController:
// group override → global storage → template default.
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _getPingOptions() async {
  final data = await _load();
  final raw = data['ping_options'];
  if (raw is Map<String, dynamic>) {
    return Map<String, dynamic>.from(raw);
  }
  return <String, dynamic>{};
}

Future<void> _savePingOptions(Map<String, dynamic> options) async {
  final data = await _load();
  data['ping_options'] = options;
  SettingsStorage._cache = data;
  await _save();
}

Future<void> _setGlobalPingUrl(String url) async {
  final opts = await SettingsStorage.getPingOptions();
  opts['url'] = url;
  await SettingsStorage.savePingOptions(opts);
}

Future<void> _setGlobalPingTimeout(int timeoutMs) async {
  final opts = await SettingsStorage.getPingOptions();
  opts['timeout_ms'] = timeoutMs;
  await SettingsStorage.savePingOptions(opts);
}

Future<void> _setGroupPing(
  String groupTag, {
  String? url,
  int? timeoutMs,
}) async {
  if (groupTag.isEmpty) return;
  final opts = await SettingsStorage.getPingOptions();
  final groups = (opts['groups'] is Map<String, dynamic>)
      ? Map<String, dynamic>.from(opts['groups'] as Map<String, dynamic>)
      : <String, dynamic>{};
  final existing = (groups[groupTag] is Map<String, dynamic>)
      ? Map<String, dynamic>.from(groups[groupTag] as Map<String, dynamic>)
      : <String, dynamic>{};
  if (url != null) existing['url'] = url;
  if (timeoutMs != null) existing['timeout_ms'] = timeoutMs;
  groups[groupTag] = existing;
  opts['groups'] = groups;
  await SettingsStorage.savePingOptions(opts);
}

Future<void> _clearGroupPing(String groupTag) async {
  if (groupTag.isEmpty) return;
  final opts = await SettingsStorage.getPingOptions();
  final groups = opts['groups'];
  if (groups is! Map<String, dynamic>) return;
  if (!groups.containsKey(groupTag)) return;
  groups.remove(groupTag);
  if (groups.isEmpty) {
    opts.remove('groups');
  } else {
    opts['groups'] = groups;
  }
  await SettingsStorage.savePingOptions(opts);
}

Future<String> _getDnsRules() async {
  final data = await _load();
  final dns = data['dns_options'] as Map<String, dynamic>?;
  if (dns == null) return '';
  return dns['rules_json'] as String? ?? '';
}

Future<void> _saveDnsRules(String rulesJson) async {
  final data = await _load();
  final dns = (data['dns_options'] as Map<String, dynamic>?) ?? {};
  dns['rules_json'] = rulesJson;
  data['dns_options'] = dns;
  SettingsStorage._cache = data;
  await _save();
}

Future<List<Map<String, dynamic>>> _getDnsRulesList() async {
  final data = await _load();
  final dns = data['dns_options'] as Map<String, dynamic>?;
  if (dns == null) return [];
  final rules = dns['rules'] as List<dynamic>?;
  if (rules == null) return [];
  return rules.whereType<Map<String, dynamic>>().toList();
}

Future<void> _saveDnsRulesList(List<Map<String, dynamic>> rules) async {
  final data = await _load();
  final dns = (data['dns_options'] as Map<String, dynamic>?) ?? {};
  dns['rules'] = rules;
  data['dns_options'] = dns;
  SettingsStorage._cache = data;
  await _save();
}
