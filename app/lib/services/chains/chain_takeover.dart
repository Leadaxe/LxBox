/// §761 — кольца и конфликты цепочек под перезапись `detour` ядра
/// (v1.14.4-lx.37-rc.2, SPEC 165 форка, ALGORITHM К1–К5).
///
/// Ядро ставит `detour` каждому узлу, до которого цепочка доходит на позиции
/// ≥ 1 (узел позиции или любой лист группы там, на любой глубине, выбранный и
/// нет, кроме `direct` и `block`). Одному узлу или группе нужен один путь.
/// Ядро на нарушение отвечает технической ошибкой и не грузит конфиг целиком.
///
/// Решение владельца 26.11: клиент кольца и конфликты НЕ разводит копиями, а
/// находит и объясняет, что сделать пользователю. Редактор не даёт сохранить,
/// сборка выбрасывает цепочку с предупреждением, конфиг собирается.
///
/// - **кольцо** — узел или группа достижимы на позиции 0 и на позиции выше той
///   же цепочки (`[A, Направление{A, X}]`), или собственный `detour` узла
///   позиции 0 ведёт в узел позиции выше;
/// - **конфликт** — узел или группа нужны цепочке на позиции ≥ 1 и
///   встречаются ещё где-то: на другой позиции ≥ 1 той же цепочки или в
///   другой цепочке на любой позиции; повтор тега. Общий вход двух цепочек
///   (один узел или Направление на позиции 0 обеих) — не конфликт.
///
/// Достижимость — по всем членам групп любой вложенности; `direct`, `block` и
/// `dns` не считаются. Чистая функция над картой тел: её зовут сборка
/// ([applyChainTakeover]) и форма цепочки.
library;

const _kGroupTypes = {'selector', 'urltest'};
const _kNoPath = {'direct', 'block', 'dns'};

/// Почему цепочка не собирается.
enum ChainTakeoverFault {
  /// Узел или группа на входе и на позиции выше той же цепочки.
  ring,

  /// Узел или группа на двух позициях ≥ 1 одной цепочки.
  twoPositions,

  /// Узел или группа нужны и другой цепочке.
  otherChain,

  /// Собственный `detour` узла позиции 0 ведёт в узел позиции выше.
  detourRing,

  /// Вложенная цепочка выше позиции 0.
  nestedChain,

  /// Тег хопа `<цепочка>#<i>` занят узлом или группой конфига.
  hopTagTaken,

  /// Позиция повторяется.
  duplicate,
}

/// Отказ одной цепочки. Позиции — с 0.
///
/// [tag] — узел или группа, которой нужны два пути; [via] — тег позиции,
/// через которую [tag] достижим на [position] (равен [tag], если он стоит
/// позицией сам). [other*] — второе место: та же цепочка или [otherChain].
/// Для [ChainTakeoverFault.detourRing] [via] — цель `detour`.
class ChainTakeoverFailure {
  const ChainTakeoverFailure({
    required this.chain,
    required this.fault,
    required this.position,
    required this.tag,
    this.via = '',
    this.otherChain = '',
    this.otherPosition = 0,
    this.otherVia = '',
  });

  final String chain;
  final ChainTakeoverFault fault;
  final int position;
  final String tag;
  final String via;
  final String otherChain;
  final int otherPosition;
  final String otherVia;

  /// Что сделать: копия какой группы и для какой позиции. Внутри цепочки —
  /// копия группы верхней позиции без [tag]; если [tag] стоит там позицией
  /// сам — копия группы нижней позиции.
  ({String group, int position})? get copyHint {
    if (via.isNotEmpty && via != tag) return (group: via, position: position);
    if (otherVia.isNotEmpty && otherVia != tag) {
      return (group: otherVia, position: otherPosition);
    }
    return null;
  }

  /// EN-строка для `emitWarnings` (позиции с 1, как в прочих строках цепочек).
  String get warning {
    final head = 'Hop chain "$chain" was dropped: ';
    final p = position + 1;
    final op = otherPosition + 1;
    final hint = copyHint;
    return head +
        switch (fault) {
          ChainTakeoverFault.ring => hint == null
              ? '"$tag" is the entry and also at position $p.'
              : hint.position == 0
                  ? '"$tag" at position $p is also inside "${hint.group}" at '
                      'the entry — make a copy of "${hint.group}" without '
                      '"$tag" for the entry.'
                  : '"$tag" is the entry and also inside "${hint.group}" at '
                      'position ${hint.position + 1} — make a copy of '
                      '"${hint.group}" without "$tag" for this position.',
          ChainTakeoverFault.twoPositions => hint == null
              ? '"$tag" is at positions $op and $p.'
              : '"$tag" is at positions $op and $p — make a copy of '
                  '"${hint.group}" without "$tag" for position '
                  '${hint.position + 1}.',
          ChainTakeoverFault.otherChain =>
            '"$tag" is used in chains "$otherChain" (position $op) and '
                '"$chain" (position $p) — make a copy of "$tag" (and its '
                'nodes; WireGuard copies need other keys) for one of them.',
          ChainTakeoverFault.detourRing =>
            'the detour of "$tag" at the entry leads to "$via", which the '
                'chain takes over higher up — remove that detour or take '
                '"$via" out of this chain.',
          ChainTakeoverFault.nestedChain =>
            'nested chain "$tag" at position $p — a nested chain is only '
                'allowed at the entry.',
          ChainTakeoverFault.hopTagTaken =>
            'the tag "$tag" is taken by a node or group; the core needs it '
                'for the chain\'s hop — rename that node.',
          ChainTakeoverFault.duplicate =>
            '"$tag" is used more than once — one node or group has one path.',
        };
  }
}

/// Узлы и группы конфига: тег → (секция, тело).
typedef ChainBodies = Map<String, ({String section, Map<String, dynamic> body})>;

ChainBodies chainBodiesOf(Map<String, dynamic> config) {
  final out = <String, ({String section, Map<String, dynamic> body})>{};
  for (final key in const ['outbounds', 'endpoints']) {
    final list = config[key];
    if (list is! List) continue;
    for (final e in list) {
      if (e is Map<String, dynamic> && e['tag'] is String) {
        out[e['tag'] as String] = (section: key, body: e);
      }
    }
  }
  return out;
}

/// Отказы цепочек [chains] (теги в порядке объявления) над [bodies].
/// Во втором месте конфликта стоит цепочка выше по списку — выпадает
/// нижняя. Цепочка, выпавшая сама, мест не занимает.
List<ChainTakeoverFailure> checkChainTakeover(
  ChainBodies bodies,
  List<String> chains,
) {
  // Тег → места в собранных цепочках выше: (цепочка, позиция, через что).
  final claimed = <String, List<({String chain, int position, String via})>>{};
  final failures = <ChainTakeoverFailure>[];
  for (final chainTag in chains) {
    final raw = bodies[chainTag]?.body['outbounds'];
    if (raw is! List) continue;
    final positions = [for (final p in raw) '$p'];
    final r = _checkOne(chainTag, positions, bodies, claimed);
    if (r.failure != null) {
      failures.add(r.failure!);
      continue;
    }
    for (final e in r.reached.entries) {
      claimed.putIfAbsent(e.key, () => []).add(
          (chain: chainTag, position: e.value.position, via: e.value.via));
    }
  }
  return failures;
}

({ChainTakeoverFailure? failure, Map<String, ({int position, String via})> reached})
    _checkOne(
  String chainTag,
  List<String> positions,
  ChainBodies bodies,
  Map<String, List<({String chain, int position, String via})>> claimed,
) {
  const none = <String, ({int position, String via})>{};
  ChainTakeoverFailure fail(
    ChainTakeoverFault f,
    int i,
    String tag, {
    String via = '',
    String otherChain = '',
    int otherPosition = 0,
    String otherVia = '',
  }) =>
      ChainTakeoverFailure(
        chain: chainTag,
        fault: f,
        position: i,
        tag: tag,
        via: via,
        otherChain: otherChain,
        otherPosition: otherPosition,
        otherVia: otherVia,
      );

  final seen = <String>{};
  for (var i = 0; i < positions.length; i++) {
    if (!seen.add(positions[i])) {
      return (
        failure: fail(ChainTakeoverFault.duplicate, i, positions[i]),
        reached: none
      );
    }
  }
  for (var i = 0; i < positions.length; i++) {
    final hop = '$chainTag#$i';
    if (bodies.containsKey(hop)) {
      return (
        failure: fail(ChainTakeoverFault.hopTagTaken, i, hop),
        reached: none
      );
    }
  }

  // Тег → первое место в этой цепочке.
  final reached = <String, ({int position, String via})>{};
  for (var i = 0; i < positions.length; i++) {
    final p = positions[i];
    final entry = bodies[p];
    // Висячую позицию судит граф-санитайзер сборки.
    if (entry == null) continue;
    if (entry.body['type'] == 'chain') {
      if (i >= 1) {
        return (
          failure: fail(ChainTakeoverFault.nestedChain, i, p),
          reached: none
        );
      }
      continue;
    }
    // Обход в глубину, группа раньше членов: первым найдётся верхний общий
    // тег (группа, а не её узел).
    final order = <String>[];
    void walk(String tag, Set<String> path) {
      final b = bodies[tag]?.body;
      if (b == null) return;
      final t = b['type'];
      if (_kNoPath.contains(t) || t == 'chain') return;
      if (!path.add(tag)) return;
      if (!order.contains(tag)) order.add(tag);
      if (_kGroupTypes.contains(t)) {
        for (final m in (b['outbounds'] as List? ?? const [])) {
          walk('$m', path);
        }
      }
      path.remove(tag);
    }

    walk(p, <String>{});
    for (final tag in order) {
      final prev = reached[tag];
      if (prev != null && prev.position != i) {
        final f = prev.position == 0
            ? ChainTakeoverFault.ring
            : ChainTakeoverFault.twoPositions;
        return (
          failure: fail(f, i, tag,
              via: p,
              otherChain: chainTag,
              otherPosition: prev.position,
              otherVia: prev.via),
          reached: none
        );
      }
      for (final c in claimed[tag] ?? const <({String chain, int position, String via})>[]) {
        // Общий вход двух цепочек — не конфликт.
        if (c.position == 0 && i == 0) continue;
        return (
          failure: fail(ChainTakeoverFault.otherChain, i, tag,
              via: p,
              otherChain: c.chain,
              otherPosition: c.position,
              otherVia: c.via),
          reached: none
        );
      }
      reached.putIfAbsent(tag, () => (position: i, via: p));
    }
  }

  // Кольцо через detour: узел позиции 0 идёт своим путём, и если этот путь
  // (detour с переходами по detour и членам групп) заходит в узел позиции
  // выше — кольцо.
  final upper = {
    for (final e in reached.entries)
      if (e.value.position >= 1) e.key,
  };
  if (upper.isNotEmpty) {
    final entryLeaves = [
      for (final e in reached.entries)
        if (e.value.position == 0 &&
            !_kGroupTypes.contains(bodies[e.key]?.body['type']))
          e.key,
    ];
    for (final leaf in entryLeaves) {
      final start = bodies[leaf]?.body['detour'];
      if (start is! String) continue;
      final queue = [start];
      final visited = <String>{};
      while (queue.isNotEmpty) {
        final t = queue.removeLast();
        if (!visited.add(t)) continue;
        if (upper.contains(t)) {
          return (
            failure: fail(ChainTakeoverFault.detourRing, 0, leaf, via: t),
            reached: none
          );
        }
        final b = bodies[t]?.body;
        if (b == null) continue;
        if (_kGroupTypes.contains(b['type'])) {
          for (final m in (b['outbounds'] as List? ?? const [])) {
            queue.add('$m');
          }
        }
        final d = b['detour'];
        if (d is String) queue.add(d);
      }
    }
  }
  return (failure: null, reached: reached);
}

/// Сборка: цепочки с кольцом или конфликтом сняты из `outbounds` (ссылки на
/// них дочищает граф-санитайзер). Возвращает строки для `emitWarnings`.
List<String> applyChainTakeover(Map<String, dynamic> config) {
  final bodies = chainBodiesOf(config);
  final chains = [
    for (final e in bodies.entries)
      if (e.value.body['type'] == 'chain') e.key,
  ];
  if (chains.isEmpty) return const [];
  final failures = checkChainTakeover(bodies, chains);
  if (failures.isEmpty) return const [];
  final dropped = {for (final f in failures) f.chain};
  final list = config['outbounds'];
  if (list is List) {
    list.removeWhere((e) => e is Map && dropped.contains(e['tag']));
  }
  return [for (final f in failures) f.warning];
}
