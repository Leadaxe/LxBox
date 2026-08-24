part of '../settings_storage.dart';

// §393 C2 / D1 — источники-цепочки (`chains[]`) для [SettingsStorage].
//
// Вынесено `part`'ом по образцу `directions.dart` — та же библиотека, тот же
// доступ к `_load`/`_save`/`_cache`, тот же паттерн read-весь-объект →
// mutate-copy → rewrite-atomically.
//
// ─── Где живёт цепочка (директива оператора 24.08) ──────────────────────────
//
// Цепочка — ТАКОЙ ЖЕ ИСТОЧНИК, как подписка, одиночный сервер и папка: она
// стоит СТРОКОЙ в общем списке источников и перетаскивается наравне со всеми
// (так же у лаунчера — `source_tab`, один список). Отдельной секции «Цепочки
// хопов» больше нет.
//
// ХРАНЕНИЕ при этом осталось своим ключом `chains[]`, а не переехало в
// `server_lists`. Причина — цена, а не вкус: `ServerList` это sealed-тип
// «контейнер узлов» (`nodes`, `tagPrefix`, `detourPolicy`, fetch/parse), и
// его подтип разбирается по всему коду в 53 местах. У цепочки нет ни узлов,
// ни префикса, ни detour-политики: она бы вошла туда вырожденным членом,
// который каждый из этих 53 сайтов обязан пропускать особым случаем. Общий
// список источников — это UI-порядок, и достаточно, чтобы цепочка имела в
// нём МЕСТО ([SourceChain.order]), а не чтобы она стала контейнером узлов.
//
// ─── Почему место — поле, а не порядок массива ──────────────────────────────
//
// Массив `chains[]` хранит только ВЗАИМНЫЙ порядок цепочек. А инвариант
// «позиция вправе сослаться только на цепочку ВЫШЕ» считается по ОБЩЕМУ
// списку, и `order` — единственное, чем можно ответить на вопрос «стоит ли
// эта цепочка выше вон той подписки». Именно это снимает страх старого
// дизайна: перетащить подписку МЕЖДУ двумя цепочками теперь законно —
// взаимный порядок цепочек от этого не меняется, и ни одна ссылка не
// ломается.
//
// Инвариант списка, который держит этот файл: `_getChains` ВСЕГДА возвращает
// цепочки в порядке `order` (записи без него — в конец, взаимный порядок
// сохранён). Билдер (`resolveChains`), T9 и экспорт бэкапа читают список
// сверху вниз и получают ровно тот порядок, который пользователь видит на
// экране, — им ничего не пришлось знать про `order`.

/// §393 D1 — цепочки в порядке ОБЩЕГО списка источников.
///
/// ПОРЯДОК НОРМАТИВЕН: цепочка вправе сослаться только на стоящую ВЫШЕ, и
/// этим исключены циклы между цепочками (канон `source_chain.schema.json`,
/// тот же приём, что `include` у Направлений).
///
/// Сортировка стабильная и терпимая к мусору: записи без `order` (-1: старый
/// storage, импорт из бэкапа, правленый файл) встают в КОНЕЦ, сохраняя
/// взаимный порядок файла. Дубли `order` разрешаются порядком файла — дыры и
/// повторы законны, значение имеет только относительный порядок.
Future<List<SourceChain>> _getChains() async {
  final data = await _load();
  final raw = data['chains'] as List<dynamic>? ?? const [];
  final chains =
      raw.whereType<Map<String, dynamic>>().map(SourceChain.fromJson).toList();
  return _sortChainsByOrder(chains);
}

/// Стабильная сортировка по [SourceChain.order]; `-1` («не назначена») — в
/// конец. Отдельной функцией, потому что тем же порядком пользуются миграция
/// и merge импорта, а `List.sort` в Dart НЕ стабилен — сравниваем индексом
/// файла как вторичным ключом.
List<SourceChain> _sortChainsByOrder(List<SourceChain> chains) {
  final indexed = [
    for (var i = 0; i < chains.length; i++) (chain: chains[i], at: i),
  ];
  indexed.sort((a, b) {
    final ao = a.chain.order < 0 ? _kChainOrderUnset : a.chain.order;
    final bo = b.chain.order < 0 ? _kChainOrderUnset : b.chain.order;
    if (ao != bo) return ao.compareTo(bo);
    return a.at.compareTo(b.at); // стабильность: порядок файла
  });
  return [for (final e in indexed) e.chain];
}

/// Сортировочный вес записи без назначенной позиции: «ниже любой назначенной».
const int _kChainOrderUnset = 1 << 30;

/// Записать список цепочек, ПРОНУМЕРОВАВ его позициями общего списка.
///
/// Нумерация идёт от текущей длины `server_lists`: цепочки — часть общего
/// списка источников, а UI рисует их после подписок ровно в этом порядке.
/// Абсолютные значения не важны (важен только относительный порядок), но
/// держать их за пределами диапазона подписок дешевле, чем пересчитывать
/// весь общий список на каждую правку одной цепочки.
Future<void> _setChains(List<SourceChain> chains, {bool flush = true}) async {
  final data = await _load();
  final base = (data['server_lists'] as List<dynamic>?)?.length ?? 0;
  // Порядок ПЕРЕДАННОГО списка — источник истины: вызывающий уже расставил
  // цепочки так, как они должны стоять. Перенумеровываем подряд, чтобы после
  // удалений и вставок не копились дыры.
  data['chains'] = [
    for (var i = 0; i < chains.length; i++)
      chains[i].copyWith(order: base + i).toJson(),
  ];
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113 — config-significant
  if (flush) await _save();
}

/// §393 D1 — one-shot миграция: цепочкам из старого storage (ключ `chains`
/// без поля `order` — он уже в проде у dev-сборок) назначаются позиции
/// общего списка.
///
/// Цепочки встают в КОНЕЦ общего списка, ВЗАИМНЫЙ порядок сохранён — ровно
/// то, что пользователь видел до перехода на общий список (отдельная секция
/// рисовалась над подписками, но ссылки между цепочками считались по их
/// собственному порядку, и он единственный, что нужно сберечь).
///
/// Идемпотентна и дёшева: проверка идёт по СЫРОМУ списку (`map['order']`),
/// без `SourceChain.fromJson`. На самом частом пути (позиции уже назначены)
/// — один линейный проход и ноль записей на диск. Маркер не нужен: «у всех
/// записей есть order» — само по себе устойчивое состояние, а пустой список
/// цепочек мигрировать не от чего.
Future<void> _migrateChainOrderIfNeeded() async {
  final data = await _load();
  final raw = data['chains'];
  if (raw is! List || raw.isEmpty) return;
  final entries = raw.whereType<Map<String, dynamic>>().toList();
  if (entries.isEmpty) return;
  // Уже мигрировано — самый частый путь.
  if (entries.every((e) => e['order'] is int)) return;

  // Порядок ФАЙЛА и есть взаимный порядок цепочек: до §393 D1 он был
  // единственным, и именно по нему считался инвариант «ссылка только вверх».
  // Смешанный случай (часть записей с позицией, часть без) разрешается тем же
  // общим правилом: назначенные — по своей позиции, остальные — в конец.
  final chains = entries.map(SourceChain.fromJson).toList();
  await _setChains(_sortChainsByOrder(chains));
}

/// Создать цепочку. [tag] — по умолчанию первый свободный `chain-N`
/// ([nextChainTag]).
///
/// Встаёт в КОНЕЦ общего списка источников: новая цепочка не может быть
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
  // Позицию проставил `_setChains` — возвращаем запись такой, какой она легла
  // на диск, иначе вызывающий получил бы `order: -1` и записал бы его обратно.
  return (await _getChains()).firstWhere((c) => c.tag == wanted);
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
/// [chain] приходит с любым `order` (обычно -1) — позицию назначает
/// [_setChains], ставя запись в конец общего списка.
Future<SourceChain> _createChain(SourceChain chain) async {
  final chains = (await _getChains()).toList();
  // Гейт возвращает тег ПОСЛЕ trim — записываем именно его, иначе на диск
  // легла бы одна форма тега, а проверялась другая (и `chain.tag` с пробелами
  // разошёлся бы с тем, на что ссылаются позиции).
  final wanted = await _requireFreeChainTag(chain.tag, chains);
  chains.add(SourceChain(
    tag: wanted,
    label: chain.label,
    enabled: chain.enabled,
    hops: chain.hops,
    idleTimeout: chain.idleTimeout,
    stripEvasion: chain.stripEvasion,
    strip: chain.strip,
    rewrite: chain.rewrite,
  ));
  await _setChains(chains);
  return (await _getChains()).firstWhere((c) => c.tag == wanted);
}

/// Обновить цепочку по [SourceChain.tag]. Throws, если тег не найден.
///
/// Позиция в общем списке НЕ меняется: правка маршрута — не перемещение
/// источника. `order` пришедшей записи игнорируется (её место держит индекс
/// в списке, который перенумеровывает [_setChains]).
Future<void> _updateChain(SourceChain chain) async {
  final chains = (await _getChains()).toList();
  final i = chains.indexWhere((c) => c.tag == chain.tag);
  if (i < 0) throw StateError('chain not found: ${chain.tag}');
  chains[i] = chain;
  await _setChains(chains);
}

/// §393 D1 — переставить цепочки в их ВЗАИМНОМ порядке.
///
/// Принимает полный список в новом порядке (как `bulkReplace` у Направлений).
/// Состав обязан совпадать с текущим — метод только переставляет; проверять
/// это здесь нечем и незачем, вызывающий один (drag в общем списке).
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

/// §393 D2 — вычистить позиции с тегом [tag] из ВСЕХ цепочек storage.
///
/// Единственная точка каскада для удаления ЧУЖОГО источника (одиночный
/// сервер, подписка целиком, папка, Направление) — удаление самой цепочки
/// идёт через [_deleteChain], которому нужно ещё и убрать запись.
///
/// Ничего не нашлось → ноль записей на диск: heal зовётся на КАЖДОМ удалении
/// источника, а цепочек у большинства пользователей нет вовсе.
Future<ChainHealResult> _healChainHops(String tag, {bool flush = true}) async {
  final chains = await _getChains();
  final healed = clearChainHopRefs(chains, tag);
  if (healed.positions == 0) return healed;
  await _setChains(healed.chains, flush: flush);
  return healed;
}
