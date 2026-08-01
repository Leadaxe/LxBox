import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/node_spec.dart';
import '../models/template_vars.dart';

/// §283 — стабильная идентичность ноды подписки.
///
/// Ключ per-node disable — хеш «сервер целиком + все параметры», а не tag
/// (провайдеры переименовывают косметически) и не позиция (состав подписки
/// дышит на каждом refresh). Формула:
///
///   sha256( jsonEncode( deepSortKeys( emit(TemplateVars.empty).map
///                                     − 'tag' − 'detour' ) ) )
///
/// - `emit(TemplateVars.empty)` — канонический sing-box-map узла; vars на
///   emit сегодня не влияет (tls_fragment — post-step), UI уже использует
///   этот паттерн (node_settings_screen).
/// - `tag`/`detour` — ровно два контекстных поля map (ремарка юзера и tag
///   chained-ноды), не свойства сервера. Всё остальное — суть узла.
/// - deepSortKeys — иначе хеш зависел бы от insertion order полей эмиттера.
///
/// Свойства: переименование ноды провайдером хеш не меняет; смена сути
/// (порт/uuid/sni) — меняет; дубли одного сервера с разными лейблами дают
/// один хеш (один toggle гасит все — by design).

/// TTL спящей отметки: hash удаляется, если источник не появлялся в подписке
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

/// Identity-хеш ноды (hex sha256). См. док модуля.
String nodeIdentityHash(NodeSpec node) {
  final map = Map<String, dynamic>.from(node.emit(TemplateVars.empty).map)
    ..remove('tag')
    ..remove('detour');
  return sha256.convert(utf8.encode(jsonEncode(deepSortKeys(map)))).toString();
}

/// §283 — GC отметок на успешном СЕТЕВОМ refresh (и только на нём: failed
/// refresh / регидрация из кэша / file:-подписки не несут сигнала об уходе
/// ноды). Хеш найден в свежем теле → lastSeen = now; не найден дольше
/// TTL-порога → отметка удаляется.
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
