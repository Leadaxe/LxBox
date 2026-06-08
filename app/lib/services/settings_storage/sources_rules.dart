part of '../settings_storage.dart';

// Server lists / enabled rules+groups / global-update / rule-outbounds /
// custom rules для [SettingsStorage].
//
// Вынесено `part`'ом — та же библиотека, тот же доступ к `_load`/`_save`/
// `_cache`. Семантика storage-ключей и миграций идентична исходнику.

// ---------------------------------------------------------------------------
// Server lists (v2). Ключ на диске: `server_lists`.
//
// Миграция с v1 (`proxy_sources`): при первом чтении, если старый ключ
// есть и новый пустой — конвертируем через `migrateProxySources`, пишем
// в новый ключ, старый удаляем. Необратимо.
// ---------------------------------------------------------------------------

Future<List<ServerList>> _getServerLists() async {
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
  SettingsStorage._cache = data;
  await _save();
  return migrated;
}

Future<void> _saveServerLists(List<ServerList> lists) async {
  final data = await _load();
  data['server_lists'] = lists.map((e) => e.toJson()).toList();
  data.remove('proxy_sources');
  SettingsStorage._cache = data;
  await _save();
}

// ---------------------------------------------------------------------------
// Enabled selectable rules
// ---------------------------------------------------------------------------

Future<Set<String>> _getEnabledRules() async {
  final data = await _load();
  final list = data['enabled_rules'] as List<dynamic>? ?? [];
  return list.map((e) => e.toString()).toSet();
}

Future<void> _saveEnabledRules(Set<String> rules) async {
  final data = await _load();
  data['enabled_rules'] = rules.toList();
  SettingsStorage._cache = data;
  await _save();
}

// ---------------------------------------------------------------------------
// Enabled preset groups
// ---------------------------------------------------------------------------

Future<Set<String>> _getEnabledGroups() async {
  final data = await _load();
  final list = data['enabled_groups'] as List<dynamic>? ?? [];
  return list.map((e) => e.toString()).toSet();
}

Future<void> _saveEnabledGroups(Set<String> groups) async {
  final data = await _load();
  data['enabled_groups'] = groups.toList();
  SettingsStorage._cache = data;
  await _save();
}

// ---------------------------------------------------------------------------
// Last global update timestamp
// ---------------------------------------------------------------------------

Future<DateTime?> _getLastGlobalUpdate() async {
  final data = await _load();
  final raw = data['last_global_update'] as String?;
  if (raw == null) return null;
  return DateTime.tryParse(raw);
}

Future<void> _setLastGlobalUpdate(DateTime dt) async {
  final data = await _load();
  data['last_global_update'] = dt.toIso8601String();
  SettingsStorage._cache = data;
  await _save();
}

Duration? _parseReloadInterval(String reload) {
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

Future<bool> _shouldRefreshSubscriptions(String reloadInterval) async {
  final interval = SettingsStorage.parseReloadInterval(reloadInterval);
  if (interval == null) return false;
  final lastUpdate = await SettingsStorage.getLastGlobalUpdate();
  if (lastUpdate == null) return true;
  return DateTime.now().difference(lastUpdate) >= interval;
}

// ---------------------------------------------------------------------------
// Rule outbounds: Map<ruleLabel, outboundTag>
// ---------------------------------------------------------------------------

Future<Map<String, String>> _getRuleOutbounds() async {
  final data = await _load();
  final map = data['rule_outbounds'] as Map<String, dynamic>? ?? {};
  return map.map((k, v) => MapEntry(k, v.toString()));
}

Future<void> _saveRuleOutbounds(Map<String, String> outbounds) async {
  final data = await _load();
  data['rule_outbounds'] = outbounds;
  SettingsStorage._cache = data;
  await _save();
}

// ---------------------------------------------------------------------------
// Custom rules (§030) — единая модель для domain/IP/port/package/protocol/srs.
// Per-app rules сюда же (поле `packages`), отдельного типа больше нет.
// ---------------------------------------------------------------------------

Future<List<CustomRule>> _getCustomRules() async {
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
Future<void> _absorbLegacyAppRules(Map<String, dynamic> data) async {
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
  SettingsStorage._cache = data;
  await _save();
}

Future<void> _saveCustomRules(List<CustomRule> rules) async {
  final data = await _load();
  data['custom_rules'] = rules.map((r) => r.toJson()).toList();
  SettingsStorage._cache = data;
  await _save();
}

Future<bool> _hasPresetsMigrated() async {
  final data = await _load();
  return data['presets_migrated'] == true;
}

Future<void> _markPresetsMigrated() async {
  final data = await _load();
  data['presets_migrated'] = true;
  SettingsStorage._cache = data;
  await _save();
}
