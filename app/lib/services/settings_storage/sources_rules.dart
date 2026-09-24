part of '../settings_storage.dart';

// Источники / enabled groups / global-update / custom rules для
// [SettingsStorage].
//
// Вынесено `part`'ом — та же библиотека, тот же доступ к `_load`/`_save`/
// `_cache`.

// ---------------------------------------------------------------------------
// §439/§524 — источники: записи `sources[]` контракта 1.0. ОДИН упорядоченный
// список всех родов (`subscription`/`server`/`folder`/`chain`) — супертип
// `models/source_entry.dart`, кодеки `codec/source_record.dart` (контейнеры) и
// `codec/chain_record.dart` (цепочки).
//
// §524 — ЕДИНСТВЕННЫЙ писатель массива: [_writeEntries]. До §524 их было два
// (часть без цепочек и часть цепочек), и каждый вписывал свой род в чужой
// контекст, не имея на руках чужих записей; восстановление потерянной
// информации стоило сопоставления слотов по ключу (`_spliceSourceKind`) и дало
// подряд два бага — §511 M1 (удаление сдвигало соседей того же рода) и §511 M2
// (одна нечитаемая запись отвергала любую перестановку). При едином писателе
// оба невозможны по построению: он получает весь список и пишет его целиком.
//
// Формат файла НЕ менялся: тот же ключ, те же записи, тот же порядок.
// ---------------------------------------------------------------------------

/// §524 — весь список источников в порядке `sources[]`.
///
/// Нечитаемая запись (§141 P1.8c: чужой или будущий `kind`, битый JSON) едет
/// [OpaqueEntry]'ем — она полноправный элемент списка, а не «то, чего писатель
/// не трогает». Причина уходит в [onCorrupt], остальные читаются. Прочитанное
/// не дословно (тег разошёлся с текстом, отброшенный член папки, ключи, которых
/// модель не держит) — строками в [onNote].
List<SourceEntry> _sourceEntriesOf(
  Map<String, dynamic> doc, {
  void Function(Object error)? onCorrupt,
  void Function(String note)? onNote,
}) {
  final records = _recordsAt(doc[kSourcesKey]);
  final out = <SourceEntry>[];
  for (var i = 0; i < records.length; i++) {
    final r = records[i];
    final notes = <String>[];
    if (_isChainRecord(r)) {
      final read = chainFromRecord(r, notes: notes);
      final chain = read.value;
      if (chain == null) {
        onCorrupt?.call(read.dropped!);
        out.add(OpaqueEntry(r, i));
        continue;
      }
      if (onNote != null) {
        notes.forEach(onNote);
        if (read.unknownKeys.isNotEmpty) {
          onNote('chain "${chain.tag}": keys not kept by the model: '
              '${read.unknownKeys.join(', ')}');
        }
      }
      out.add(ChainEntry(chain));
      continue;
    }
    final read = sourceFromRecord(r, notes: notes);
    final list = read.value;
    if (list == null) {
      onCorrupt?.call(read.dropped!);
      out.add(OpaqueEntry(r, i));
      continue;
    }
    if (onNote != null) {
      notes.forEach(onNote);
      if (read.unknownKeys.isNotEmpty) {
        onNote('${r['kind']} "${list.id}": keys not kept by the model: '
            '${read.unknownKeys.join(', ')}');
      }
    }
    out.add(ContainerEntry(list));
  }
  return out;
}

Future<List<SourceEntry>> _getSourceEntries() async => _sourceEntriesOf(
      await _load(),
      onCorrupt: (e) => AppLog.I.warning('Skipping unreadable source record: $e'),
      onNote: _logStorageNoteOnce,
    );

/// §524 — записать список источников ЦЕЛИКОМ, в порядке [entries].
///
/// Единственный писатель `sources[]`: сопоставлять слоты не нужно, потому что
/// чужих записей в массиве не остаётся — все они в [entries].
/// [OpaqueEntry] едет своим сырым объектом, байт в байт.
Future<void> _writeEntries(List<SourceEntry> entries,
    {bool flush = true}) async {
  final data = await _load();
  data[kSourcesKey] = [
    for (final e in entries)
      switch (e) {
        ContainerEntry(:final list) => sourceToRecord(list),
        ChainEntry(:final chain) => chainToRecord(chain),
        OpaqueEntry(:final record) => record,
      },
  ];
  SettingsStorage._cache = data;
  if (flush) await _save();
}

/// §524 — записать список источников как config-значимую правку (§113).
/// Отличие от [_writeEntries]: поднимает `configDirty`.
Future<void> _saveSourceEntries(List<SourceEntry> entries,
    {bool flush = true}) async {
  await _writeEntries(entries, flush: flush);
  SettingsStorage.markConfigDirty(); // §113
}

Future<List<ServerList>> _getServerLists() async => _serverListsOf(
      await _load(),
      onCorrupt: (e) => AppLog.I.warning('Skipping unreadable source record: $e'),
      onNote: _logStorageNoteOnce,
    );

/// Контейнеры документа хранения [doc]: живого файла, его снимка или блока
/// `storage` бэкапа — срез единого чтения [_sourceEntriesOf].
List<ServerList> _serverListsOf(
  Map<String, dynamic> doc, {
  void Function(Object error)? onCorrupt,
  void Function(String note)? onNote,
}) =>
    [
      for (final e
          in _sourceEntriesOf(doc, onCorrupt: onCorrupt, onNote: onNote))
        if (e is ContainerEntry) e.list,
    ];

/// §524 — переписать контейнеры, сохранив места и взаимный порядок остальных
/// родов. Фасад над [_writeEntries]: список читается целиком, контейнеры
/// заменяются составом [lists] по своим местам, лишние места снимаются, новые
/// записи встают в конец — сдвига соседей другого рода нет по построению.
Future<void> _saveServerLists(List<ServerList> lists,
        {bool flush = true}) async =>
    _writeEntries(
      _replaceKind<ContainerEntry>(
        await _getSourceEntries(),
        [for (final l in lists) ContainerEntry(l)],
      ),
      flush: flush,
    );

/// §524 — заменить в [all] записи рода [T] составом [ours], не двигая чужие.
///
/// Места рода [T] сопоставляются ПО КЛЮЧУ ([SourceEntry.sourceKey]), не по
/// позиции (§511 M1): место, чей ключ в [ours] есть, остаётся местом и
/// получает уцелевшие записи в порядке [ours] (так перестановка своего рода
/// пишется этой же функцией); место, чей ключ пропал, снимается целиком, и
/// соседи того же рода в него не съезжают. Записи [ours] с новыми ключами —
/// в конец списка.
///
/// Нужен фасадам `saveServerLists`/`setChains`, которые по историческим
/// причинам получают половину списка: у них на руках нет ответа, КАКОЕ из мест
/// своего рода освободилось. Единый писатель [_writeEntries] в этом не
/// нуждается — ему передают список целиком, и место каждой записи задано её
/// позицией в нём.
List<SourceEntry> _replaceKind<T extends SourceEntry>(
  List<SourceEntry> all,
  List<SourceEntry> ours,
) {
  final slotKeys = {
    for (final e in all)
      if (e is T) e.sourceKey,
  };
  final survivors = <SourceEntry>[];
  final fresh = <SourceEntry>[];
  for (final e in ours) {
    (slotKeys.contains(e.sourceKey) ? survivors : fresh).add(e);
  }
  final survivorKeys = {for (final e in survivors) e.sourceKey};
  final out = <SourceEntry>[];
  var next = 0;
  for (final e in all) {
    if (e is! T) {
      out.add(e);
    } else if (survivorKeys.contains(e.sourceKey) && next < survivors.length) {
      out.add(survivors[next++]);
    }
  }
  out
    ..addAll(survivors.skip(next))
    ..addAll(fresh);
  return out;
}

Future<List<String>> _getSourceKeys() async =>
    [for (final e in await _getSourceEntries()) e.sourceKey];

/// §524 — перестановка `sources[]`. [keys] — новый порядок записей
/// ([SourceEntry.sourceKey]): каждый ключ есть в списке ровно один раз и не
/// повторяется в [keys]; иначе no-op — состав списка эта операция не меняет.
///
/// Записи вне [keys] (нечитаемые, §141 P1.8c) остаются в своих слотах; слоты
/// записей из [keys] заполняются в порядке [keys] (§511 M2).
///
/// `false` — перестановка отвергнута, причина уходит в AppLog (§511 m4):
/// раньше отказ был тихим, и строка на экране просто отпрыгивала назад.
Future<bool> _reorderSources(List<String> keys) async {
  final entries = await _getSourceEntries();
  bool reject(String why) {
    AppLog.I.warning('reorderSources rejected: $why '
        '(keys=${keys.length}, records=${entries.length})');
    return false;
  }

  final want = keys.toSet();
  if (want.length != keys.length) return reject('duplicate key');
  final byKey = <String, SourceEntry>{};
  for (final e in entries) {
    final k = e.sourceKey;
    if (!want.contains(k)) continue;
    if (byKey.containsKey(k)) return reject('ambiguous record $k');
    byKey[k] = e;
  }
  if (byKey.length != keys.length) {
    return reject('unknown key ${want.difference(byKey.keys.toSet()).first}');
  }
  var next = 0;
  await _saveSourceEntries([
    for (final e in entries)
      want.contains(e.sourceKey) ? byKey[keys[next++]]! : e,
  ]);
  return true;
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
