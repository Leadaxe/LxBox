part of '../settings_storage.dart';

// §393 C2 — источники-цепочки (`chains[]`) для [SettingsStorage].
//
// Вынесено `part`'ом по образцу `directions.dart` — та же библиотека, тот же
// доступ к `_load`/`_save`/`_cache`, тот же паттерн read-весь-объект →
// mutate-copy → rewrite-atomically.
//
// ОТДЕЛЬНЫЙ список, а не поле подписки и не Направление (§393 L5): цепочка —
// это МАРШРУТ, третий тип источника рядом с подпиской и сервером. Узлы
// подписки производны от её тела и пере-создаются на каждом обновлении;
// цепочка написана пользователем руками и обязана пережить и обновление
// подписки, и её удаление (позиция превратится в висячую — билдер
// деградирует ЦЕПОЧКУ с warning `chain_hop_missing`, но данные пользователя
// не трогает).
//
// Миграции здесь нет и не нужно: ключ новый, отсутствие `chains` = «цепочек
// нет» — состояние, неотличимое от «пользователь их все удалил», и разницы
// между ними не существует (в отличие от `directions`, где пустой список
// значил бы потерю роутинга и требовал seed'а).

/// §393 C2 — все цепочки в порядке объявления. ПОРЯДОК НОРМАТИВЕН: цепочка
/// вправе сослаться только на объявленную ВЫШЕ по этому списку, и этим
/// исключены циклы между цепочками (канон `source_chain.schema.json`, тот же
/// приём, что `include` у Направлений).
Future<List<SourceChain>> _getChains() async {
  final data = await _load();
  final raw = data['chains'] as List<dynamic>? ?? const [];
  return raw.whereType<Map<String, dynamic>>().map(SourceChain.fromJson).toList();
}

Future<void> _setChains(List<SourceChain> chains, {bool flush = true}) async {
  final data = await _load();
  data['chains'] = chains.map((c) => c.toJson()).toList();
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113 — config-significant
  if (flush) await _save();
}

/// Создать цепочку. [tag] — по умолчанию первый свободный `chain-N`
/// ([nextChainTag]).
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
  final chain = SourceChain(tag: wanted, label: label ?? wanted, enabled: true);
  chains.add(chain);
  await _setChains(chains);
  return chain;
}

/// Обновить цепочку по [SourceChain.tag]. Throws, если тег не найден.
Future<void> _updateChain(SourceChain chain) async {
  final chains = (await _getChains()).toList();
  final i = chains.indexWhere((c) => c.tag == chain.tag);
  if (i < 0) throw StateError('chain not found: ${chain.tag}');
  chains[i] = chain;
  await _setChains(chains);
}

/// Удалить цепочку.
///
/// Ссылки на удалённый тег в ПОЗИЦИЯХ других цепочек НЕ вычищаются — в
/// отличие от `include` Направлений (§393 A3), где вычистка идёт на удалении.
/// Асимметрия намеренная: снятие одной позиции превращает маршрут в ДРУГОЙ
/// маршрут (`[home, de, exit]` без `de` — это уже не «через Германию»), и
/// молча его подменить нельзя. Билдер вместо этого деградирует цепочку с
/// висячей позицией ЦЕЛИКОМ (`chain_hop_missing`), а пользователь видит её в
/// списке и правит осознанно — либо вернув источник, либо переписав маршрут.
///
/// Ссылки на цепочку как на detour-мишень / цель правил не лечатся по той же
/// причине, по которой не лечатся ссылки на исчезнувший узел подписки: тег
/// цепочки для остального приложения — обычный тег узла, и его исчезновение
/// разгребает граф-санитайзер сборки (§393 A4).
Future<void> _deleteChain(String tag) async {
  final chains = (await _getChains()).toList()..removeWhere((c) => c.tag == tag);
  await _setChains(chains);
}
