import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/node_spec.dart';
import '../models/template_vars.dart';

/// §400 / контракт 0.10.0 (SPEC 112) — идентичность узла подписки.
///
///   identity = uniquify_within_source( raw_provider_tag )
///
/// - `raw_provider_tag` — `NodeSpec.tag`: в LxBox он уже сырой, наш
///   `tag_prefix` клеится позже и только в билдере
///   (`TagResolver.displayTag`, `server_list_build.dart`). Значит смена
///   префикса подписки идентичность не двигает;
/// - уникализация — та же машина, что у конфиговых тегов: первый `X`,
///   следующий `X-2`, затем `X-3`; порядок — порядок разбора, счётчик свой
///   на источник (не глобальный);
/// - узлы-группы (§322 `AutoSelectSpec`) и узлы без имени идентичности НЕ
///   имеют — пустая строка это «идентичности нет», а не общий ключ.
///
/// Содержимое узла (server, port, креды, SNI, транспорт, mtu) в
/// идентичность не входит: провайдер вправе ротировать адрес под тем же
/// именем — это ТОТ ЖЕ узел, и отметка выключения обязана за ним следовать.
/// Прежний контент-хеш (см. [legacyNodeIdentityHash]) считал такую ротацию
/// появлением нового узла и молча снимал отметку.
///
/// Цена модели названа прямо: переименование узла провайдером отметку
/// теряет — имя и есть идентичность. Отметка не переезжает на чужой узел,
/// она доживает в карте и уходит по TTL.

/// TTL спящей отметки: ключ удаляется, если источник не появлялся в подписке
/// дольше `clamp(3 × updateIntervalHours, пол, потолок)` (решения юзера
/// 2026-07-18: пол — сутки, потолок — месяц).
const int kDisabledHashTtlIntervals = 3;
const int kDisabledHashTtlFloorHours = 24;
const int kDisabledHashTtlCeilHours = 24 * 30;

/// Порог TTL для интервала обновления подписки. `interval <= 0`
/// схлопывается в пол. Для file:-подписок GC не зовётся вовсе (guard в
/// _fetchEntryByRef — нет сетевого refresh = нет сигнала «нода ушла»);
/// online-подписка с interval -1/0 («не обновлять авто») при РУЧНОМ refresh
/// GC проходит — это настоящий сетевой fetch, порог = пол (24ч).
Duration disabledHashTtl(int updateIntervalHours) {
  final hours = kDisabledHashTtlIntervals *
      (updateIntervalHours > 0 ? updateIntervalHours : 0);
  return Duration(
      hours:
          hours.clamp(kDisabledHashTtlFloorHours, kDisabledHashTtlCeilHours));
}

/// Карта «узел → идентичность» для ОДНОГО источника.
///
/// Функция чистая и считается от всего списка узлов, а не от одного узла:
/// уникализация зависит от соседей, так что идентичность в принципе не
/// вычислима по узлу в отрыве от источника. Все потребители (билдер,
/// контроллер, probe, экран деталей) обязаны брать ключи отсюда — иначе две
/// стороны разойдутся в нумерации тёзок.
///
/// Карта по ссылке (`Map.identity`): `NodeSpec.==` сравнивает `id`+`tag`, и
/// два разных узла-тёзки из одного тела схлопнулись бы в одну ячейку.
/// Узлы без идентичности (группы, безымянные) в карту НЕ попадают — вызов
/// `map[node]` даёт `null`, и это единственная трактовка «отметки нет».
Map<NodeSpec, String> sourceNodeIdentities(List<NodeSpec> nodes) {
  final out = Map<NodeSpec, String>.identity();
  if (nodes.isEmpty) return out;
  final counts = <String, int>{};
  for (final node in nodes) {
    final id = _stampIdentity(node, counts);
    if (id != null) out[node] = id;
  }
  return out;
}

/// Идентичность одного узла с занятием имени в счётчике источника.
/// `null` — идентичности нет (группа или пустой тег).
String? _stampIdentity(NodeSpec node, Map<String, int> counts) {
  if (node.isGroup) return null;
  final raw = node.tag.trim();
  if (raw.isEmpty) return null;
  return _uniquifyAgainstCounts(raw, counts);
}

/// Подбирает свободное имя вида `X`, `X-2`, `X-3` и занимает его.
///
/// Кандидат проверяется на занятость: сгенерированное `X-2` может уже
/// принадлежать настоящему имени из подписки. Тело `X, X-2, X` без проверки
/// дало бы `X, X-2, X-2` — две идентичности с одним ключом, и одна отметка
/// гасила бы оба узла.
String _uniquifyAgainstCounts(String name, Map<String, int> counts) {
  if ((counts[name] ?? 0) == 0) {
    counts[name] = 1;
    return name;
  }
  while (true) {
    counts[name] = (counts[name] ?? 0) + 1;
    final candidate = '$name-${counts[name]}';
    if ((counts[candidate] ?? 0) == 0) {
      counts[candidate] = 1;
      return candidate;
    }
  }
}

/// Рекурсивная сортировка ключей Map (вглубь Map/List) — детерминированный
/// вход для jsonEncode независимо от порядка полей в коде эмиттера.
/// Ключи канонизируются toString() ЧЕРЕЗ entries (lookup по исходному
/// ключу), чтобы не-строковый ключ не терял значение.
dynamic deepSortKeys(dynamic value) {
  if (value is Map) {
    final entries = [
      for (final e in value.entries)
        MapEntry(e.key.toString(), deepSortKeys(e.value)),
    ]..sort((a, b) => a.key.compareTo(b.key));
    return <String, dynamic>{for (final e in entries) e.key: e.value};
  }
  if (value is List) return [for (final e in value) deepSortKeys(e)];
  return value;
}

/// УПРАЗДНЁННАЯ идентичность (§283, до контракта 0.10.0): sha256 от
/// эмитированного sing-box-map узла без полей `tag`/`detour`, с рекурсивно
/// отсортированными ключами.
///
/// Идентичностью БОЛЬШЕ НЕ ЯВЛЯЕТСЯ. Два оставшихся применения:
///
/// 1. миграция ключей (IDENTITY.md §5.1) — по нему опознаются отметки,
///    записанные до перехода на тег;
/// 2. отпечаток СОДЕРЖИМОГО узла (§331/§360 composition key): вопрос
///    «изменилось ли то, что уйдёт в конфиг» — не про идентичность. Контракт
///    разрешает эту роль прямо (IDENTITY.md §1.2: у Go тот же алгоритм живёт
///    подписью дедупа), отпечаток никуда не персистится.
///
/// Алгоритм обязан остаться воспроизводимым, пока в природе есть
/// непереехавшие состояния (в Go — `LegacyNodeIdentityHash`).
String legacyNodeIdentityHash(NodeSpec node) {
  final map = Map<String, dynamic>.from(node.emit(TemplateVars.empty).map)
    ..remove('tag')
    ..remove('detour');
  return sha256.convert(utf8.encode(jsonEncode(deepSortKeys(map)))).toString();
}

/// Ключ формы «64 lowercase hex» — legacy-хеш (IDENTITY.md §5.1 п.1).
/// Тег такой формы теоретически возможен, но провайдер, назвавший узел
/// 64 hex-символами, теряет ровно одну отметку — против гарантии, что все
/// настоящие legacy-ключи опознаются.
bool isLegacyIdentityKey(String key) {
  if (key.length != 64) return false;
  for (var i = 0; i < 64; i++) {
    final c = key.codeUnitAt(i);
    final isDigit = c >= 0x30 && c <= 0x39;
    final isLowerHex = c >= 0x61 && c <= 0x66;
    if (!isDigit && !isLowerHex) return false;
  }
  return true;
}

/// Миграция ключей отметок (IDENTITY.md §5.1). Зовётся при ПЕРВОМ разборе
/// источника, по ПОЛНОМУ списку узлов (до фильтра выключенных: legacy-ключ
/// опознаётся именно по выключенному узлу).
///
/// 1. Ключ не 64-hex — уже идентичность, оставляем как есть.
/// 2. Legacy-хеш совпал с хешем узла источника → отметка переезжает на его
///    идентичность, время сохраняется (при коллизии побеждает более свежий
///    lastSeen).
/// 3. Не совпал → ключ выбрасывается: узла с таким содержимым в источнике
///    нет, отметка и так мертва.
///
/// Идемпотентна: на второй заход legacy-ключей в карте уже нет, и функция
/// возвращает исходную карту без копирования. Результат обязан быть
/// сохранён вызывающим — иначе прогон повторяется на каждом запуске.
///
/// Возвращает ту же карту (identical), если мигрировать нечего — вызывающий
/// по этому признаку решает, нужен ли лишний persist.
Map<String, DateTime> migrateLegacyDisabledKeys(
  Map<String, DateTime> current,
  List<NodeSpec> nodes,
) {
  if (current.isEmpty) return current;
  final legacyKeys = [
    for (final k in current.keys)
      if (isLegacyIdentityKey(k)) k,
  ];
  if (legacyKeys.isEmpty) return current;

  // Хеш считаем один раз на узел и только когда есть что мигрировать:
  // эмиссия десятка тысяч узлов недешёвая.
  final identities = sourceNodeIdentities(nodes);
  final byLegacyHash = <String, String>{};
  for (final node in nodes) {
    final identity = identities[node];
    if (identity == null) continue;
    // Первый узел с этим содержимым и побеждает: дубли по содержимому
    // различаются только именем, и отметке нужно ОДНО из них.
    byLegacyHash.putIfAbsent(legacyNodeIdentityHash(node), () => identity);
  }

  final next = <String, DateTime>{};
  for (final e in current.entries) {
    if (!isLegacyIdentityKey(e.key)) {
      next[e.key] = e.value;
      continue;
    }
    final identity = byLegacyHash[e.key];
    if (identity == null) continue; // п.4 — узла нет, ключ выбрасываем
    final existing = next[identity];
    if (existing == null || existing.isBefore(e.value)) {
      next[identity] = e.value;
    }
  }
  return next;
}

/// §283 — GC отметок на успешном СЕТЕВОМ refresh (и только на нём: failed
/// refresh / регидрация из кэша / file:-подписки не несут сигнала об уходе
/// ноды). Идентичность найдена в свежем теле → lastSeen = now; не найдена
/// дольше TTL-порога → отметка удаляется.
Map<String, DateTime> gcDisabledHashes(
  Map<String, DateTime> current,
  Set<String> freshHashes, {
  required int updateIntervalHours,
  required DateTime now,
}) {
  if (current.isEmpty) return current;
  final ttl = disabledHashTtl(updateIntervalHours);
  final next = <String, DateTime>{};
  current.forEach((hash, lastSeen) {
    if (freshHashes.contains(hash)) {
      next[hash] = now;
    } else if (now.difference(lastSeen) <= ttl) {
      next[hash] = lastSeen;
    }
    // else: источник не появлялся дольше порога — отметка истекла.
  });
  return next;
}

/// §332 — накладывает итог enable/disable-правил на карту отметок (после GC):
/// ENABLE снимает отметку (в том числе ручную §283 — правило-источник истины,
/// когда матчится), DISABLE ставит со свежим lastSeen. Наборы по построению
/// не пересекаются (итог по узлу один — движок §302 разрешает конфликт
/// «последнее правило побеждает» ещё per-node).
Map<String, DateTime> applyRuleMarks(
  Map<String, DateTime> base, {
  required Set<String> enable,
  required Set<String> disable,
  required DateTime now,
}) {
  if (enable.isEmpty && disable.isEmpty) return base;
  return {
    for (final e in base.entries)
      if (!enable.contains(e.key)) e.key: e.value,
    for (final h in disable) h: now,
  };
}
