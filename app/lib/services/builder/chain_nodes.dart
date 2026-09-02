// §393 C3 — превращение источников-цепочек в УЗЛЫ конфига (SPEC 110).
//
// Порт `core/config/chain_nodes.go` лаунчера.
//
// ПОЧЕМУ НЕ ВНУТРИ ИСТОЧНИКА. Цепочка ссылается на теги, которые становятся
// окончательными только ПОСЛЕ загрузки всех источников: подписка
// переименовывает узлы префиксом и уникализирует дубли, а Направления и вовсе
// разворачиваются позже. Поэтому цепочка не может собраться там же, где
// сервер из URI, — её узел строится здесь, когда весь пул уже известен.
//
// ПОРЯДОК РАЗРЕШЕНИЯ — по списку цепочек, и цепочка вправе сослаться только
// на цепочку, объявленную ВЫШЕ. Так вложенность остаётся выразимой, но циклы
// между цепочками невозможны ПО ПОСТРОЕНИЮ — ровно тем же приёмом, что
// `include` у Направлений (§393 A3). Ссылка вперёд неотличима от ссылки в
// никуда и деградирует цепочку так же (`chain_hop_missing`).
//
// ДЕГРАДАЦИЯ — ЦЕЛИКОМ, а не «пропустить позицию»: маршрут без хопа это
// ДРУГОЙ маршрут. Молча подменить его — то же самое, что молча сменить
// страну выхода.

import '../../models/source_chain.dart';
import 'core_chain_capability.dart';

/// Цепочка, не ставшая узлом, и почему.
///
/// Не «тихо пропустить»: пользователь настроил маршрут, видит его в списке
/// источников и вправе узнать, почему трафик пошёл не туда.
class ChainDegradation {
  const ChainDegradation({
    required this.tag,
    required this.label,
    required this.reason,
    required this.code,
  });

  final String tag;
  final String label;

  /// Готовая EN-строка для `emitWarnings`.
  final String reason;

  /// Код реестра (`registry/warnings.json`): `chain_unsupported_by_core`,
  /// `chain_invalid`, `chain_hop_missing`, `chain_nested_position`.
  /// Нужен раннеру корпуса и диагностике — текст меняется, код нет.
  final String code;
}

/// Результат разрешения цепочек в узлы.
class ChainResolution {
  const ChainResolution({required this.nodes, required this.degraded});

  /// Готовые outbound-объекты типа `chain`, в порядке списка цепочек.
  final List<Map<String, dynamic>> nodes;

  /// Цепочки, не доехавшие до конфига.
  final List<ChainDegradation> degraded;

  /// Теги эмитированных цепочек — они уходят в пул отбора Направлений
  /// наравне с узлами подписок.
  List<String> get tags =>
      [for (final n in nodes) n['tag'] as String? ?? ''];
}

/// §393 C3 — разрешает [chains] в узлы конфига.
///
/// [knownTags] — теги, на которые позиция вправе сослаться: узлы всех
/// источников, Направления (включая выключенные — их теги зарезервированы
/// аллокатором, §351) и служебные теги шаблона. Множество мутируется по мере
/// разрешения: тег каждой успешной цепочки добавляется в него, и следующая
/// цепочка может им воспользоваться.
///
/// [coreVersion] — строка `Libbox.version()`. Гейт §393 C5 стоит ПЕРВЫМ:
/// ядро без `with_lx_chain` отвергает конфиг ЦЕЛИКОМ на неизвестном типе
/// outbound'а, то есть одна настроенная цепочка оставила бы пользователя
/// вообще без VPN.
ChainResolution resolveChains(
  List<SourceChain> chains, {
  required Set<String> knownTags,
  String coreVersion = '',
}) {
  final nodes = <Map<String, dynamic>>[];
  final degraded = <ChainDegradation>[];
  // Конфиги без цепочек обязаны собираться ровно так же, как раньше, не
  // платя ни за один лишний проход.
  final live = [for (final c in chains) if (c.enabled) c];
  if (live.isEmpty) return ChainResolution(nodes: nodes, degraded: degraded);

  final supported = coreSupportsChain(coreVersion);
  // Теги уже разрешённых цепочек: по ним отличается ВЛОЖЕННАЯ цепочка от
  // обычного узла (ядро допускает её только позицией 0).
  final chainTags = <String>{};

  for (final c in live) {
    void degrade(String code, String reason) =>
        degraded.add(ChainDegradation(
            tag: c.tag, label: c.tag, reason: reason, code: code));

    if (!supported) {
      degrade('chain_unsupported_by_core',
          chainUnsupportedByCoreLine(c.tag, coreVersion));
      continue;
    }
    // Инварианты ядра — до всего остального: собственные диагностики цепочки
    // информативнее, чем «имя занято» у записи, которая и так не взлетела бы.
    final invalid = chainEmitError(c);
    if (invalid.isNotEmpty) {
      degrade('chain_invalid',
          'Hop chain "${c.tag}" was skipped: $invalid.');
      continue;
    }
    // Коллизия имени: цепочка, названная как существующий узел, Направление
    // или другая цепочка, дала бы два outbound'а с одним тегом — ядро
    // отвергает такой конфиг целиком. Узлы подписок через это не проходят
    // (аллокатор тегов), цепочки идут мимо него.
    if (knownTags.contains(c.tag)) {
      degrade(
          'chain_invalid',
          'Hop chain "${c.tag}" was skipped: the tag "${c.tag}" is '
              'already taken by another outbound, direction or chain.');
      continue;
    }
    // Позиция, которой нет среди известных тегов, — ссылка в никуда, на
    // которой ядро не стартует. Сюда же попадает ссылка ВПЕРЁД на цепочку,
    // объявленную ниже: её тега в `knownTags` ещё нет, и это ровно тот
    // порядок, которым исключены циклы.
    var missing = '';
    var missingAt = 0;
    for (var i = 0; i < c.hops.length; i++) {
      if (!knownTags.contains(c.hops[i])) {
        missing = c.hops[i];
        missingAt = i + 1;
        break;
      }
    }
    if (missing.isNotEmpty) {
      degrade(
          'chain_hop_missing',
          'Hop chain "${c.tag}" was dropped: position $missingAt '
              '("$missing") was not found among nodes, directions and chains '
              'declared above it. A route without a hop is a different route, '
              'so the whole chain is skipped.');
      continue;
    }
    // Вложенная цепочка законна ТОЛЬКО позицией 0: звено — это «узел через
    // предыдущую позицию», а цепочка не узел и не пересобирается под чужой
    // диалер (`protocol/chain/chain.go:279`). `check` этого не ловит —
    // падает только `run` (§393 L4).
    final nested = <String>[];
    for (var i = 1; i < c.hops.length; i++) {
      if (chainTags.contains(c.hops[i])) nested.add(c.hops[i]);
    }
    if (nested.isNotEmpty) {
      degrade(
          'chain_nested_position',
          'Hop chain "${c.tag}" was dropped: nested chains '
              '${nested.map((t) => '"$t"').join(', ')} are not at position 1 — '
              'the core allows a nested chain only as the first hop.');
      continue;
    }

    nodes.add(chainOutboundObject(c));
    knownTags.add(c.tag);
    chainTags.add(c.tag);
  }
  return ChainResolution(nodes: nodes, degraded: degraded);
}

// ── T9: цепочка через Направление (§393 C4, L6) ─────────────────────────────
//
// Порт `core/config/chain_cycle.go` лаунчера.
//
// В первой редакции цепочка была Направлением, и циклы были невозможны по
// построению. Когда цепочка стала источником, то есть УЗЛОМ, это свойство
// исчезло — а ломающий его сценарий самый частый из всех:
//
//     цепочка «через Германию наружу» = [proxy-out, exit-node]
//     proxy-out — Направление с фильтром «все узлы» → ловит и саму цепочку
//     ⇒ proxy-out содержит цепочку, которая идёт через proxy-out
//
// Ядро на таком не падает — оно разворачивает позицию в тот outbound, который
// группа выбрала СЕЙЧАС, — но пользователь получает маршрут, которого не
// задумывал: выбрав цепочку внутри proxy-out, он замыкает трафик на неё же.
// Плюс подменяет смысл самой цепочки: «через Германию» превращается в «через
// то, что сейчас выбрано, а выбрано может быть это же».

/// Карта «тег цепочки → её позиции» по ЭМИТИРОВАННЫМ узлам.
///
/// Строится по узлам, а не по источникам: к этому моменту деградировавшие
/// цепочки уже отсеяны, и только у узла тег окончателен.
Map<String, List<String>> chainHopsByTag(List<Map<String, dynamic>> chainNodes) {
  final out = <String, List<String>>{};
  for (final n in chainNodes) {
    final tag = n['tag'];
    if (tag is! String || tag.isEmpty) continue;
    out[tag] = [
      for (final h in (n['outbounds'] as List? ?? const []))
        if (h is String) h,
    ];
  }
  return out;
}

/// Проходит ли цепочка [chainTag] через тег [target] — ТРАНЗИТИВНО, через
/// вложенные цепочки.
///
/// `seen` защищает от зацикливания на испорченных данных: [resolveChains]
/// циклов не создаёт, но эта функция не должна зависеть от чужих инвариантов,
/// чтобы не подвесить сборку.
bool chainPassesThrough(
  String chainTag,
  String target,
  Map<String, List<String>> hopsByTag, [
  Set<String>? seen,
]) {
  final visited = seen ?? <String>{};
  if (!visited.add(chainTag)) return false;
  for (final hop in hopsByTag[chainTag] ?? const <String>[]) {
    if (hop == target) return true;
    if (hopsByTag.containsKey(hop) &&
        chainPassesThrough(hop, target, hopsByTag, visited)) {
      return true;
    }
  }
  return false;
}

/// §393 C4 / T9 — убирает из отобранного состава [nodes] цепочки, проходящие
/// через Направление [directionTag].
///
/// Зовётся ПОСЛЕ фильтра Направления: фильтр не знает, что такое цепочка, и
/// знать не должен — «все узлы» обязано означать все узлы.
///
/// Вторым значением — теги выброшенных цепочек: это предупреждение
/// пользователю (`chain_cycle_through_direction`), а не внутренняя деталь. Он
/// собрал маршрут и вправе знать, почему тот не появился в группе.
({List<String> kept, List<String> dropped}) dropChainsThroughDirection(
  List<String> nodes,
  String directionTag,
  Map<String, List<String>> hopsByTag,
) {
  if (directionTag.isEmpty || hopsByTag.isEmpty) {
    return (kept: nodes, dropped: const []);
  }
  // Сначала считаем, есть ли что выбрасывать: без цепочек в составе (а это
  // подавляющее большинство Направлений) вход возвращается КАК ЕСТЬ, и
  // конфиги без цепочек собираются байт-в-байт как раньше.
  final cyclic = <String>{};
  for (final tag in nodes) {
    if (!hopsByTag.containsKey(tag) || cyclic.contains(tag)) continue;
    if (chainPassesThrough(tag, directionTag, hopsByTag)) cyclic.add(tag);
  }
  if (cyclic.isEmpty) return (kept: nodes, dropped: const []);
  final kept = <String>[];
  final dropped = <String>[];
  for (final tag in nodes) {
    if (cyclic.contains(tag)) {
      if (!dropped.contains(tag)) dropped.add(tag);
      continue;
    }
    kept.add(tag);
  }
  return (kept: kept, dropped: dropped);
}

/// EN-строка предупреждения `chain_cycle_through_direction`.
String chainCycleThroughDirectionLine(String directionLabel, List<String> chains) {
  final list = chains.map((t) => '"$t"').join(', ');
  final subject = chains.length == 1 ? 'Hop chain $list runs' : 'Hop chains $list run';
  return '$subject through direction "$directionLabel" and '
      '${chains.length == 1 ? 'was' : 'were'} left out of it — otherwise '
      'picking the chain inside that direction would loop the traffic back '
      'onto itself. The chain is still available in other directions.';
}
