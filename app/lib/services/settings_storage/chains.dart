part of '../settings_storage.dart';

// §393 C2 / D1 — источники-цепочки для [SettingsStorage].
//
// Вынесено `part`'ом по образцу `directions.dart` — та же библиотека, тот же
// доступ к `_load`/`_save`/`_cache`, тот же паттерн read-весь-объект →
// mutate-copy → rewrite-atomically.
//
// ─── Где живёт цепочка ──────────────────────────────────────────────────────
//
// Цепочка — такой же источник, как подписка, одиночный сервер и папка: она
// стоит строкой в общем списке источников и перетаскивается наравне со всеми
// (директива оператора 24.08; так же у лаунчера). §439 / §509: хранение это
// повторяет — записи `kind: chain` лежат в `sources[]` среди остальных
// источников, место — индекс записи (BACKUP §4: порядок записей нормативен).
// Отдельного ключа и поля позиции нет.
//
// Модели при этом разные: `ServerList` — sealed-тип «контейнер узлов», и
// цепочка вошла бы в него вырожденным членом, которого каждый сайт разбора
// обязан пропускать. Поэтому два репозитория над одним массивом:
// `sources_rules.dart` читает и переписывает часть без цепочек, этот файл —
// часть цепочек. Каждый писатель вставляет свой род в СУЩЕСТВУЮЩИЕ слоты
// (`_spliceSourceKind`), не склеивая «сначала узлы, потом цепочки». Полная
// перестановка общего списка — `reorderSources`.
//
// Инвариант «позиция вправе сослаться только на цепочку ВЫШЕ» считается по
// взаимному порядку цепочек: сервер или подписка между двумя цепочками
// законны, ни одна ссылка от этого не ломается.

/// §393 D1 — цепочки в их взаимном порядке (порядок записей `sources[]`).
///
/// ПОРЯДОК НОРМАТИВЕН: цепочка вправе сослаться только на стоящую ВЫШЕ, и
/// этим исключены циклы между цепочками (канон `source_chain.schema.json`,
/// тот же приём, что `include` у Направлений).
Future<List<SourceChain>> _getChains() async => _chainsOf(
      await _load(),
      onCorrupt: (e) => AppLog.I.warning('Skipping unreadable chain record: $e'),
      onNote: _logStorageNoteOnce,
    );

/// Цепочки документа хранения [doc] (живой файл, снимок, блок `storage`
/// бэкапа). Запись без тега не адресуема — причина уходит в [onCorrupt];
/// прочитанное не дословно — строками в [onNote].
List<SourceChain> _chainsOf(
  Map<String, dynamic> doc, {
  void Function(Object error)? onCorrupt,
  void Function(String note)? onNote,
}) {
  final out = <SourceChain>[];
  for (final r in _recordsAt(doc[kSourcesKey])) {
    if (!_isChainRecord(r)) continue;
    final notes = <String>[];
    final read = chainFromRecord(r, notes: notes);
    final chain = read.value;
    if (chain == null) {
      onCorrupt?.call(read.dropped!);
      continue;
    }
    if (onNote != null) {
      notes.forEach(onNote);
      if (read.unknownKeys.isNotEmpty) {
        onNote('chain "${chain.tag}": keys not kept by the model: '
            '${read.unknownKeys.join(', ')}');
      }
    }
    out.add(chain);
  }
  return out;
}

/// Записать цепочки в порядке [chains], не трогая слоты прочих источников.
/// Новая цепочка, которой не хватило слота, встаёт в конец массива.
Future<void> _setChains(List<SourceChain> chains, {bool flush = true}) async {
  final data = await _load();
  data[kSourcesKey] = _spliceSourceKind(
    existing: _recordsAt(data[kSourcesKey]),
    ours: [for (final c in chains) chainToRecord(c)],
    isOurs: _isChainRecord,
  );
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113 — config-significant
  if (flush) await _save();
}

/// Создать цепочку. [tag] — по умолчанию первый свободный `chain-N`
/// ([nextChainTag]).
///
/// Встаёт в конец общего списка источников: новая цепочка не может быть
/// чьей-то позицией (на неё ещё никто не ссылается), а сама вправе сослаться
/// на всё, что стоит выше, — то есть на весь существующий список.
///
/// Конфликт тега проверяется по ДВУМ спискам сразу — цепочек и Направлений:
/// одинаковый тег дал бы два outbound'а с одним именем, и ядро отвергло бы
/// конфиг целиком. Узлы подписок в проверку не входят намеренно: их теги
/// зависят от тела подписки и меняются при каждом обновлении, а коллизию с
/// ними разруливает аллокатор тегов билдера (тот же путь, что у Направлений,
/// §351 — узел-тёзка получает суффикс). Машинный код причины — в тексте
/// [StateError], как у [_addDirection].
Future<SourceChain> _addChain({String? label, String? tag}) async {
  final chains = (await _getChains()).toList();
  final wanted = await _requireFreeChainTag(tag, chains);
  final chain = SourceChain(tag: wanted, label: label ?? wanted, enabled: true);
  chains.add(chain);
  await _setChains(chains);
  return chain;
}

/// §393 D3 — общий гейт тега для создания цепочки: пустой / служебный / дубль
/// по цепочкам И Направлениям / тёзка чьего-либо `<tag>-auto`.
///
/// Вынесен из [_addChain], потому что тем же гейтом обязан пройти атомарный
/// `POST /chains` (§393 D3): он собирает полную запись ДО записи на диск и
/// не может позволить себе «создать, потом проверить».
Future<String> _requireFreeChainTag(String? tag, List<SourceChain> chains) async {
  final directions = await _getDirections();
  final used = [
    ...chains.map((c) => c.tag),
    ...directions.map((d) => d.tag),
  ];
  final wanted = (tag ?? nextChainTag(used)).trim();
  final conflict = directionTagConflict(wanted, used);
  if (conflict != null) {
    throw StateError('chain tag "$wanted" rejected: $conflict');
  }
  return wanted;
}

/// §393 D3 — создать цепочку ЦЕЛИКОМ, одной операцией.
///
/// Отличие от [_addChain]: запись ложится на диск уже полной. Прежний
/// `POST /chains` создавал пустую запись, затем применял поля и валидировал —
/// и отказ (400) оставлял в storage пустой огрызок, которого пользователь не
/// просил. Здесь вызывающий валидирует [chain] ДО вызова, а storage делает
/// ровно одну запись: не прошло — не записалось.
///
/// Запись встаёт в конец общего списка источников.
Future<SourceChain> _createChain(SourceChain chain) async {
  final chains = (await _getChains()).toList();
  // Гейт возвращает тег ПОСЛЕ trim — записываем именно его, иначе на диск
  // легла бы одна форма тега, а проверялась другая (и `chain.tag` с пробелами
  // разошёлся бы с тем, на что ссылаются позиции).
  final wanted = await _requireFreeChainTag(chain.tag, chains);
  final created = SourceChain(
    tag: wanted,
    label: chain.label,
    enabled: chain.enabled,
    hops: chain.hops,
    idleTimeout: chain.idleTimeout,
    stripEvasion: chain.stripEvasion,
    strip: chain.strip,
    rewrite: chain.rewrite,
  );
  chains.add(created);
  await _setChains(chains);
  return created;
}

/// Обновить цепочку по [SourceChain.tag]. Throws, если тег не найден.
///
/// Позиция в общем списке НЕ меняется: правка маршрута — не перемещение
/// источника.
Future<void> _updateChain(SourceChain chain) async {
  final chains = (await _getChains()).toList();
  final i = chains.indexWhere((c) => c.tag == chain.tag);
  if (i < 0) throw StateError('chain not found: ${chain.tag}');
  chains[i] = chain;
  await _setChains(chains);
}

/// §393 D1 — переставить цепочки в их взаимном порядке, не двигая чужие
/// слоты. Смешение с подписками и серверами — [SettingsStorage.reorderSources].
Future<void> _reorderChains(List<SourceChain> chains) => _setChains(chains);

/// Удалить цепочку.
///
/// §393 D2 — ПОЗИЦИИ с тегом удалённой вычищаются из ОСТАЛЬНЫХ цепочек, сами
/// они остаются (директива оператора 24.08). Каскад рекурсивен только через
/// цепочки-позиции: удаление A убирает позицию A из B, а B живёт дальше.
///
/// Прежде ссылки не чистились вовсе, и цепочка с висячей позицией
/// деградировала целиком (`chain_hop_missing`). Директива поменяла границу:
/// ОСОЗНАННОЕ удаление источника пользователем — это высказывание про состав,
/// и маршрут переживает его укороченным. Последствия приняты явно:
///   • цепочка, упавшая ниже двух позиций, остаётся в storage, но не
///     эмитится (`chainEmitError` → `tooFewHops`) — чинит пользователь;
///   • цепочка 3+ хопов эмитится УКОРОЧЕННЫМ маршрутом.
/// Поэтому вычистка обязана быть ЗАМЕТНОЙ: счётчик уезжает вызывающему
/// ([ChainHealResult]) и показывается тем же механизмом, что rules/detours/
/// includes-heal (§202/§248).
///
/// Граница (решение оператора): пропажа узла при ОБНОВЛЕНИИ подписки сюда НЕ
/// попадает — там остаётся деградация билдера `chain_hop_missing`. Узел может
/// вернуться следующим обновлением, и фоновое событие не вправе молча резать
/// маршруты, которые пользователь написал руками.
Future<ChainHealResult> _deleteChain(String tag) async {
  final chains = (await _getChains()).toList()..removeWhere((c) => c.tag == tag);
  final healed = clearChainHopRefs(chains, tag);
  await _setChains(healed.chains);
  return healed;
}

/// §393 D2 — вычистить позиции-корневые ссылки на [tag] из ВСЕХ цепочек
/// storage.
///
/// Каскад удаления Направления; удаление самой цепочки идёт через
/// [_deleteChain], которому нужно ещё и убрать запись. Ссылки на узлы гасит
/// реестр ссылок (`node_link_registry.dart`).
///
/// Ничего не нашлось → ноль записей на диск: цепочек у большинства
/// пользователей нет вовсе.
Future<ChainHealResult> _healChainHops(String tag, {bool flush = true}) async {
  final chains = await _getChains();
  final healed = clearChainHopRefs(chains, tag);
  if (healed.positions == 0) return healed;
  await _setChains(healed.chains, flush: flush);
  return healed;
}
