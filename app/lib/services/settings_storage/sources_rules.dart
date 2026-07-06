part of '../settings_storage.dart';

// Server lists / enabled rules+groups / global-update / rule-outbounds /
// custom rules для [SettingsStorage].
//
// Вынесено `part`'ом — та же библиотека, тот же доступ к `_load`/`_save`/
// `_cache`. Семантика storage-ключей и миграций идентична исходнику.

// ---------------------------------------------------------------------------
// Server lists (v2). Ключ на диске: `server_lists`.
//
// §159 — legacy-миграция v1 (`proxy_sources` → `server_lists`) удалена. Старый
// ключ (если ещё лежит у кого-то на диске) безвреден и отбросится при первом
// импорте бэкапа allowlist'ом.
// ---------------------------------------------------------------------------

Future<List<ServerList>> _getServerLists() async {
  final data = await _load();
  final v2 = data['server_lists'] as List<dynamic>?;
  if (v2 == null) return const [];
  // §141 P1.8c — per-entry try/catch: одна битая запись (unknown type,
  // missing required field → FormatException в *.fromJson) раньше роняла
  // ВЕСЬ список → app не загружал ни одной подписки. Теперь skip битой
  // записи с логом, остальные подгружаются.
  return v2
      .whereType<Map<String, dynamic>>()
      .map((m) {
        try {
          return ServerList.fromJson(m);
        } catch (e) {
          AppLog.I.warning('Skipping corrupt server_list entry: $e');
          return null;
        }
      })
      .whereType<ServerList>()
      .toList();
}

Future<void> _saveServerLists(List<ServerList> lists, {bool flush = true}) async {
  final data = await _load();
  data['server_lists'] = lists.map((e) => e.toJson()).toList();
  SettingsStorage._cache = data;
  if (flush) await _save();
}

// §159 — `enabled_rules` API удалён (legacy-миграция в `custom_rules` снята).

// ---------------------------------------------------------------------------
// Enabled preset groups
// ---------------------------------------------------------------------------

Future<Set<String>> _getEnabledGroups() async {
  final data = await _load();
  final list = data['enabled_groups'] as List<dynamic>? ?? [];
  return list.map((e) => e.toString()).toSet();
}

Future<void> _saveEnabledGroups(Set<String> groups,
    {bool flush = true}) async {
  final data = await _load();
  data['enabled_groups'] = groups.toList();
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113
  if (flush) await _save();
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

// §159 — `rule_outbounds` API удалён (legacy-миграция в `custom_rules` снята).

// ---------------------------------------------------------------------------
// Custom rules (§030) — единая модель для domain/IP/port/package/protocol/srs.
// Per-app rules сюда же (поле `packages`), отдельного типа больше нет.
// ---------------------------------------------------------------------------

Future<List<CustomRule>> _getCustomRules() async {
  final data = await _load();
  // §159 — legacy `app_rules` → `custom_rules` миграция удалена.
  final list = data['custom_rules'] as List<dynamic>? ?? [];
  return list
      .whereType<Map<String, dynamic>>()
      .map(CustomRule.fromJson)
      .toList();
}

Future<void> _saveCustomRules(List<CustomRule> rules,
    {bool flush = true}) async {
  final data = await _load();
  data['custom_rules'] = rules.map((r) => r.toJson()).toList();
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113
  if (flush) await _save();
}

/// §228 — маппинг переименованных preset_id. Пресеты `bittorrent-direct` /
/// `private-ip-direct` потеряли суффикс `-direct` (теперь у них выбираемый
/// outbound, а не захардкоженный direct), `block_unknown` приведён к
/// kebab-case. Без ремапа сохранённые у юзеров правила ссылались бы на
/// несуществующий preset_id → «Preset not found» + осиротевший
/// `varsValues['outbound']`.
const _renamedPresetIds = <String, String>{
  'bittorrent-direct': 'bittorrent',
  'private-ip-direct': 'private-ip',
  'block_unknown': 'unknown-traffic',
};

/// §228 — one-shot ремап preset_id в сохранённых `custom_rules`. Переписывает
/// ТОЛЬКО `presetId`, `varsValues` (в т.ч. выбранный юзером outbound) остаётся
/// нетронутым → выбор канала переживает переименование. Guard `preset_ids_remapped`.
/// Идемпотентна. ДОЛЖНА идти до seed'а дефолтных пресетов (иначе уже засеянные
/// юзеры не отремапятся).
///
/// ТЕХДОЛГ §229: удалить эту функцию + `_renamedPresetIds` в следующем релизе
/// ПОСЛЕ выхода §228 в прод (миграция одноразовая; guard-ключ сохранить).
/// См. docs/spec/tasks/229-remove-preset-id-migration.md.
Future<void> _migrateRenamedPresetIds() async {
  final data = await _load();
  if (data['preset_ids_remapped'] == true) return;

  final list = data['custom_rules'];
  if (list is List) {
    var changed = false;
    for (final e in list) {
      if (e is Map &&
          e['kind'] == 'preset' &&
          _renamedPresetIds.containsKey(e['presetId'])) {
        e['presetId'] = _renamedPresetIds[e['presetId']];
        changed = true;
      }
    }
    if (changed) data['custom_rules'] = list;
  }

  data['preset_ids_remapped'] = true;
  SettingsStorage._cache = data;
  await _save();
}

/// §159 — флаг «дефолтные пресеты уже засеяны» (fresh-install seed). Хранится
/// в том же storage-ключе `presets_migrated`, что и снятая legacy-миграция —
/// чтобы юзеры, уже прошедшие миграцию, НЕ получили повторный seed дефолтов.
Future<bool> _hasDefaultsSeeded() async {
  final data = await _load();
  return data['presets_migrated'] == true;
}

Future<void> _markDefaultsSeeded() async {
  final data = await _load();
  data['presets_migrated'] = true;
  SettingsStorage._cache = data;
  await _save();
}
