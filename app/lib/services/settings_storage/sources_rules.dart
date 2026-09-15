part of '../settings_storage.dart';

// Источники / enabled groups / global-update / custom rules для
// [SettingsStorage].
//
// Вынесено `part`'ом — та же библиотека, тот же доступ к `_load`/`_save`/
// `_cache`.

// ---------------------------------------------------------------------------
// §439 — источники: записи `sources[]` контракта 1.0 кодеком
// `models/codec/source_record.dart`. Цепочки лежат в том же массиве хвостом
// (`chains.dart`); здесь читается и переписывается только часть без них.
// ---------------------------------------------------------------------------

Future<List<ServerList>> _getServerLists() async => _serverListsOf(
      await _load(),
      onCorrupt: (e) => AppLog.I.warning('Skipping unreadable source record: $e'),
      onNote: _logStorageNoteOnce,
    );

/// Источники документа хранения [doc]: живого файла, его снимка или блока
/// `storage` бэкапа — одно чтение на все случаи.
///
/// Запись, которую кодек не читает (нет `kind` или `id`, чужой вид), в
/// список не попадает: причина уходит в [onCorrupt], остальные читаются
/// (§141 P1.8c). Прочитанное не дословно (тег записи разошёлся с текстом,
/// отброшенный член папки, ключи, которых модель не держит) — строками в
/// [onNote].
List<ServerList> _serverListsOf(
  Map<String, dynamic> doc, {
  void Function(Object error)? onCorrupt,
  void Function(String note)? onNote,
}) {
  final out = <ServerList>[];
  for (final r in _recordsAt(doc[kSourcesKey])) {
    if (_isChainRecord(r)) continue;
    final notes = <String>[];
    final read = sourceFromRecord(r, notes: notes);
    final list = read.value;
    if (list == null) {
      onCorrupt?.call(read.dropped!);
      continue;
    }
    if (onNote != null) {
      notes.forEach(onNote);
      if (read.unknownKeys.isNotEmpty) {
        onNote('${r['kind']} "${list.id}": keys not kept by the model: '
            '${read.unknownKeys.join(', ')}');
      }
    }
    out.add(list);
  }
  return out;
}

/// Переписать часть `sources[]` без цепочек; записи цепочек остаются
/// хвостом в своём порядке.
Future<void> _saveServerLists(List<ServerList> lists, {bool flush = true}) async {
  final data = await _load();
  data[kSourcesKey] = [
    for (final l in lists) sourceToRecord(l),
    for (final r in _recordsAt(data[kSourcesKey]))
      if (_isChainRecord(r)) r,
  ];
  SettingsStorage._cache = data;
  if (flush) await _save();
}

/// Объекты-записи массива [raw]; не объекты пропускаются.
List<Map<String, dynamic>> _recordsAt(Object? raw) => raw is List
    ? [
        for (final e in raw)
          if (e is Map<String, dynamic>)
            e
          else if (e is Map)
            e.cast<String, dynamic>(),
      ]
    : const [];

bool _isChainRecord(Map<String, dynamic> r) => r['kind'] == kSourceKindChain;

/// Строки чтения записей в AppLog — каждая один раз за процесс: источники
/// перечитываются на каждом обращении, а расхождение живёт до следующей
/// записи.
final Set<String> _loggedStorageNotes = {};

void _logStorageNoteOnce(String note) {
  if (_loggedStorageNotes.add(note)) {
    AppLog.I.warning('SettingsStorage: $note');
  }
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
// Custom rules (§030) — записи `rules[]` контракта 1.0 кодеком
// `models/codec/rule_record.dart` (§439). Per-app rules сюда же (поле
// `packages`), отдельного типа нет.
// ---------------------------------------------------------------------------

Future<List<CustomRule>> _getCustomRules() async =>
    _customRulesOf(await _load());

/// Правила документа хранения [doc] (живой файл или блок `storage` бэкапа).
///
/// Тело, которое типизированная модель не выражает, читается правилом вида
/// json (`unknownAsVerbatim`): в конфиг оно уходит как лежит.
///
/// [onCorrupt] задан — нечитаемая запись пропускается и уходит в него: так
/// читает превью бэкапа, которому чужой файл не должен ронять диалог. Не
/// задан — [FormatException] летит вызывающему: живое хранение не вправе
/// молча выкинуть правило, которое следующая запись стёрла бы с диска.
List<CustomRule> _customRulesOf(
  Map<String, dynamic> doc, {
  void Function(Object error)? onCorrupt,
}) {
  final out = <CustomRule>[];
  for (final r in _recordsAt(doc[kRulesKey])) {
    final read = ruleFromRecord(r, unknownAsVerbatim: true);
    final rule = read.value;
    if (rule != null) {
      out.add(rule);
    } else if (onCorrupt != null) {
      onCorrupt(read.dropped!);
    } else {
      throw FormatException('unreadable rule record: ${read.dropped}');
    }
  }
  return out;
}

/// §439 В2 — json-правило с массивом раскладывается на правила по элементу
/// до кодека: запись держит один объект sing-box.
///
/// §441 — `vars` правила-пресета пишутся по нормам Н2–Н4 против шаблона
/// ([normalizePresetRulesVars]): необъявленное имя и значение, равное
/// умолчанию, снимаются молча.
Future<void> _saveCustomRules(List<CustomRule> rules,
    {bool flush = true}) async {
  final decls = await loadRecordVarDecls();
  final data = await _load();
  data[kRulesKey] = [
    for (final r in splitJsonRuleArrays(normalizePresetRulesVars(rules, decls)))
      ruleToRecord(r),
  ];
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113
  if (flush) await _save();
}

// §229 — one-shot ремап preset_id (§228: `bittorrent-direct`→`bittorrent`,
// `private-ip-direct`→`private-ip`, `block_unknown`→`unknown-traffic`) удалён:
// §228 вышел в v2.10.0, обновившиеся юзеры давно отремаплены, код был мёртвым
// грузом. Guard-ключ `preset_ids_remapped` читателей не имеет и удаляется
// миграцией §439 (имя не переиспользовать). Пропустивший v2.10.0..v2.17.x
// получит «Preset not found» на трёх старых id (мягкая деградация: warning +
// дроп при сборке).

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
