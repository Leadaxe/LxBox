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

import '../../models/node_link.dart';
import '../../models/source_chain.dart';
import '../contract/chain_strip.dart';
import '../contract/registry_warning.dart';
import 'core_chain_capability.dart';
import 'node_link_resolve.dart';

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

/// §57 — ключ каталога strip, снятый с патча цепочки ради звена, которое
/// этот путь требует (`on_hop_required` реестра). Цепочка собрана.
class ChainNote {
  const ChainNote({
    required this.tag,
    required this.label,
    required this.code,
    required this.params,
    required this.line,
  });

  final String tag;
  final String label;

  /// Код реестра (`chain_strip_utls_on_reality` и т.п.).
  final String code;
  final Map<String, String> params;

  /// Готовая EN-строка для `emitWarnings`: подпись цепочки, текст кода
  /// реестра и сам код — по нему строку находят в логе.
  final String line;
}

/// Результат разрешения цепочек в узлы.
class ChainResolution {
  const ChainResolution({
    required this.nodes,
    required this.degraded,
    this.notes = const [],
  });

  /// Готовые outbound-объекты типа `chain`, в порядке списка цепочек.
  final List<Map<String, dynamic>> nodes;

  /// Цепочки, не доехавшие до конфига.
  final List<ChainDegradation> degraded;

  /// Собранные цепочки с правкой патча по реестру (§57).
  final List<ChainNote> notes;

  /// Теги эмитированных цепочек — они уходят в пул отбора Направлений
  /// наравне с узлами подписок.
  List<String> get tags =>
      [for (final n in nodes) n['tag'] as String? ?? ''];
}

/// §393 C3 — разрешает [chains] в узлы конфига.
///
/// [knownTags] — занятые теги конфига: узлы всех источников, Направления
/// (включая выключенные — их теги зарезервированы аллокатором, §351) и
/// служебные теги шаблона. По ним ловится коллизия имени цепочки. Множество
/// мутируется: тег каждой успешной цепочки добавляется в него.
///
/// [targets] — словарь ссылок сборки (D-112): позиция-ссылка разрешается в
/// финальный тег через него. Тег успешной цепочки становится корневым именем,
/// и следующая цепочка может им воспользоваться. Без словаря (превью, тесты
/// модели) корневая позиция разрешается по [knownTags], пара — нет.
///
/// [hopBodies] — тела узлов конфига по финальному тегу: по ним реестр судит
/// `on_hop_required` каталога strip (§57). Нет тела — звено не судится.
///
/// [coreVersion] — строка `Libbox.version()`. Гейт §393 C5 стоит ПЕРВЫМ:
/// ядро без `with_lx_chain` отвергает конфиг ЦЕЛИКОМ на неизвестном типе
/// outbound'а, то есть одна настроенная цепочка оставила бы пользователя
/// вообще без VPN.
ChainResolution resolveChains(
  List<SourceChain> chains, {
  required Set<String> knownTags,
  NodeLinkTargets? targets,
  Map<String, Map<String, dynamic>> hopBodies = const {},
  String coreVersion = '',
}) {
  final nodes = <Map<String, dynamic>>[];
  final degraded = <ChainDegradation>[];
  final notes = <ChainNote>[];
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
            tag: c.tag, label: c.displayLabel, reason: reason, code: code));

    if (!supported) {
      degrade('chain_unsupported_by_core',
          chainUnsupportedByCoreLine(c.displayLabel, coreVersion));
      continue;
    }
    // Инварианты ядра — до всего остального: собственные диагностики цепочки
    // информативнее, чем «имя занято» у записи, которая и так не взлетела бы.
    final invalid = chainEmitError(c);
    if (invalid.isNotEmpty) {
      degrade('chain_invalid',
          'Hop chain "${c.displayLabel}" was skipped: $invalid.');
      continue;
    }
    // Коллизия имени: цепочка, названная как существующий узел, Направление
    // или другая цепочка, дала бы два outbound'а с одним тегом — ядро
    // отвергает такой конфиг целиком. Узлы подписок через это не проходят
    // (аллокатор тегов), цепочки идут мимо него.
    if (knownTags.contains(c.tag)) {
      degrade(
          'chain_invalid',
          'Hop chain "${c.displayLabel}" was skipped: the tag "${c.tag}" is '
              'already taken by another outbound, direction or chain.');
      continue;
    }
    // Позиция-ссылка, которая не разрешилась, — ссылка в никуда, на которой
    // ядро не стартует (NODE_LINK §5.1). Сюда же попадает ссылка ВПЕРЁД на
    // цепочку, объявленную ниже: её тега среди корневых имён ещё нет, и это
    // ровно тот порядок, которым исключены циклы.
    final hopTags = <String>[];
    NodeLink? missing;
    var missingWhy = '';
    var missingAt = 0;
    for (var i = 0; i < c.hops.length; i++) {
      final hop = c.hops[i];
      final String? tag;
      if (targets != null) {
        final r = targets.resolve(hop);
        tag = r.tag;
        missingWhy = r.reason;
      } else {
        tag = hop.isRoot && knownTags.contains(hop.tag) ? hop.tag : null;
      }
      if (tag == null) {
        missing = hop;
        missingAt = i + 1;
        break;
      }
      hopTags.add(tag);
    }
    if (missing != null) {
      // Корневая позиция без цели — прежний текст; пара и выпавший узел —
      // с причиной резолва.
      final notFound = missing.isRoot &&
          (targets == null || missingWhy.startsWith('target '));
      degrade(
          'chain_hop_missing',
          notFound
              ? 'Hop chain "${c.displayLabel}" was dropped: position $missingAt '
                  '("${missing.tag}") was not found among nodes, directions and '
                  'chains declared above it. A route without a hop is a '
                  'different route, so the whole chain is skipped.'
              : 'Hop chain "${c.displayLabel}" was dropped: position $missingAt '
                  '(${targets?.describe(missing) ?? '"${missing.tag}"'}) did not '
                  'resolve — $missingWhy. A route without a hop is a different '
                  'route, so the whole chain is skipped.');
      continue;
    }
    // Вложенная цепочка законна ТОЛЬКО позицией 0: звено — это «узел через
    // предыдущую позицию», а цепочка не узел и не пересобирается под чужой
    // диалер (`protocol/chain/chain.go:279`). `check` этого не ловит —
    // падает только `run` (§393 L4).
    final nested = <String>[];
    for (var i = 1; i < hopTags.length; i++) {
      if (chainTags.contains(hopTags[i])) nested.add(hopTags[i]);
    }
    if (nested.isNotEmpty) {
      degrade(
          'chain_nested_position',
          'Hop chain "${c.displayLabel}" was dropped: nested chains '
              '${nested.map((t) => '"$t"').join(', ')} are not at position 1 — '
              'the core allows a nested chain only as the first hop.');
      continue;
    }

    // §57 — `on_hop_required`: звено требует снимаемый путь → ключ снимается
    // с патча цепочки, цепочка собирается, код — предупреждением.
    final unstrips = chainHopUnstrips(
      stripEvasion: c.stripEvasion,
      patch: c.strip,
      hops: [for (final t in hopTags) (t, hopBodies[t])],
    );
    var emitted = c;
    if (unstrips.isNotEmpty) {
      emitted = c.copyWith(strip: applyChainUnstrips(c.strip, unstrips));
      for (final u in unstrips) {
        final params = {'target': u.target};
        notes.add(ChainNote(
          tag: c.tag,
          label: c.displayLabel,
          code: u.code,
          params: params,
          line: 'Hop chain "${c.displayLabel}": '
              '${registryText(u.code, RegistryLang.en, params: params)} '
              '[${u.code}]',
        ));
      }
    }
    nodes.add(chainOutboundObject(emitted, hopTags));
    knownTags.add(c.tag);
    targets?.addRootNames([c.tag]);
    chainTags.add(c.tag);
  }
  return ChainResolution(nodes: nodes, degraded: degraded, notes: notes);
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
