import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/custom_rule.dart';
import '../models/server_list.dart';
import 'migration/proxy_source_migration.dart';

/// Persistent storage for user settings: vars, proxy sources, enabled rules.
class SettingsStorage {
  SettingsStorage._();

  static const _fileName = 'lxbox_settings.json';
  static Map<String, dynamic>? _cache;
  static Future<void>? _pendingSave;

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<Map<String, dynamic>> _load() async {
    if (_cache != null) return _cache!;
    // Wait for any pending save to complete before loading
    if (_pendingSave != null) await _pendingSave;
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
    _cache?.remove('show_detour_servers');
    final data = Map<String, dynamic>.from(_cache ?? {});
    final f = await _file();
    _pendingSave = f.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
    );
    await _pendingSave;
    _pendingSave = null;
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

  /// Удаляет var из storage. Разница с `setVar(k, '')`:
  /// пустая строка — legitimate value, `getVar(k, default)` возвращает `''`;
  /// `removeVar` → ключ отсутствует, `getVar(k, default)` возвращает default.
  /// Используется в Debug API `DELETE /settings/vars/{key}`.
  static Future<void> removeVar(String name) async {
    final data = await _load();
    final vars = data['vars'] as Map<String, dynamic>?;
    if (vars == null || !vars.containsKey(name)) return;
    vars.remove(name);
    data['vars'] = vars;
    _cache = data;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // Server lists (v2). Ключ на диске: `server_lists`.
  //
  // Миграция с v1 (`proxy_sources`): при первом чтении, если старый ключ
  // есть и новый пустой — конвертируем через `migrateProxySources`, пишем
  // в новый ключ, старый удаляем. Необратимо.
  // ---------------------------------------------------------------------------

  static Future<List<ServerList>> getServerLists() async {
    final data = await _load();
    final v2 = data['server_lists'] as List<dynamic>?;
    if (v2 != null) {
      return v2
          .whereType<Map<String, dynamic>>()
          .map(ServerList.fromJson)
          .toList();
    }
    final v1 = data['proxy_sources'] as List<dynamic>?;
    if (v1 == null || v1.isEmpty) return const [];
    final migrated = migrateProxySources(
      v1.whereType<Map<String, dynamic>>().toList(),
    );
    data['server_lists'] = migrated.map((e) => e.toJson()).toList();
    data.remove('proxy_sources');
    _cache = data;
    await _save();
    return migrated;
  }

  static Future<void> saveServerLists(List<ServerList> lists) async {
    final data = await _load();
    data['server_lists'] = lists.map((e) => e.toJson()).toList();
    data.remove('proxy_sources');
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
  // Custom rules (§030) — единая модель для domain/IP/port/package/protocol/srs.
  // Per-app rules сюда же (поле `packages`), отдельного типа больше нет.
  // ---------------------------------------------------------------------------

  static Future<List<CustomRule>> getCustomRules() async {
    final data = await _load();
    await _absorbLegacyAppRules(data);
    final list = data['custom_rules'] as List<dynamic>? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(CustomRule.fromJson)
        .toList();
  }

  /// One-shot: legacy `app_rules` (отдельная таба до v1.3.2) → `custom_rules`
  /// с полем `packages`. Запускается один раз — после конверсии ключ удаляется.
  /// Оставлен внутри getter'а чтобы автоматически подхватиться при первом
  /// открытии Rules-таба после апдейта.
  static Future<void> _absorbLegacyAppRules(Map<String, dynamic> data) async {
    final legacy = data['app_rules'] as List<dynamic>?;
    if (legacy == null || legacy.isEmpty) return;
    final existing = (data['custom_rules'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        <Map<String, dynamic>>[];
    for (final e in legacy.whereType<Map<String, dynamic>>()) {
      final packages = (e['packages'] as List<dynamic>?)
              ?.map((p) => p.toString())
              .toList() ??
          const <String>[];
      if (packages.isEmpty) continue;
      final migrated = CustomRuleInline(
        id: (e['id'] as String?)?.trim().isNotEmpty == true
            ? e['id'] as String
            : null,
        name: (e['name'] as String?) ?? 'App group',
        enabled: (e['enabled'] as bool?) ?? true,
        packages: packages,
        outbound: (e['outbound'] as String?) ?? 'direct-out',
      );
      existing.add(migrated.toJson());
    }
    data['custom_rules'] = existing;
    data.remove('app_rules');
    _cache = data;
    await _save();
  }

  static Future<void> saveCustomRules(List<CustomRule> rules) async {
    final data = await _load();
    data['custom_rules'] = rules.map((r) => r.toJson()).toList();
    _cache = data;
    await _save();
  }

  /// Флаг one-shot миграции `enabled_rules` + `rule_outbounds` → `custom_rules`.
  /// Выставляется после первого прохода миграции в `RoutingScreen._load`.
  static Future<bool> hasPresetsMigrated() async {
    final data = await _load();
    return data['presets_migrated'] == true;
  }

  static Future<void> markPresetsMigrated() async {
    final data = await _load();
    data['presets_migrated'] = true;
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

  // ---------------------------------------------------------------------------
  // Auto-update subscriptions (§027) — global on/off gate. Manual refresh
  // работает всегда; affects только автоматические триггеры (appStart /
  // vpnConnected / periodic / vpnStopped).
  // ---------------------------------------------------------------------------

  static Future<bool> getAutoUpdateSubs() async =>
      (await getVar('auto_update_subs', 'true')) != 'false';

  static Future<void> setAutoUpdateSubs(bool enabled) =>
      setVar('auto_update_subs', enabled ? 'true' : 'false');

  // ---------------------------------------------------------------------------
  // Debug API (§031) — runtime toggle, bearer token, port.
  // ---------------------------------------------------------------------------

  static const int debugPortDefault = 9269;

  static Future<bool> getDebugEnabled() async =>
      (await getVar('debug_enabled', 'false')) == 'true';

  static Future<void> setDebugEnabled(bool enabled) =>
      setVar('debug_enabled', enabled ? 'true' : 'false');

  static Future<String> getDebugToken() async => getVar('debug_token', '');

  static Future<void> setDebugToken(String token) =>
      setVar('debug_token', token);

  static Future<int> getDebugPort() async {
    final raw = await getVar('debug_port', '$debugPortDefault');
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 1024 || parsed > 49151) {
      return debugPortDefault;
    }
    return parsed;
  }

  static Future<void> setDebugPort(int port) =>
      setVar('debug_port', port.toString());

  /// Снимок всего `_cache` для `/state/storage` (§031). Возвращает
  /// глубокую копию — сериализатор сам фильтрует по allow-list,
  /// чтобы не утекли чувствительные поля (debug_token, subscription URLs).
  static Future<Map<String, dynamic>> dumpCache() async {
    final data = await _load();
    return jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
  }
}
