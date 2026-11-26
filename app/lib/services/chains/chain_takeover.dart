/// §761 — кольца и конфликты цепочек под перезапись `detour` ядра
/// (v1.14.4-lx.37-rc.2, SPEC 165 форка, ALGORITHM К1–К6).
///
/// Ядро ставит `detour` каждому узлу, до которого цепочка доходит на позиции
/// ≥ 1 (узел позиции или любой лист группы там, на любой глубине, выбранный и
/// нет, кроме `direct` и `block`). Одному узлу или группе нужен один путь.
/// Ядро на нарушение отвечает технической ошибкой и не грузит конфиг целиком:
///
/// - **кольцо** — узел или группа достижимы на позиции 0 и на позиции выше той
///   же цепочки (`[A, Направление{A, X}]`), или собственный `detour` узла
///   позиции 0 ведёт в узел позиции выше (`circular outbound dependency` с
///   тегами хопов `<цепочка>#<i>`);
/// - **конфликт** — узел или группа в двух цепочках на любых позициях или на
///   двух позициях ≥ 1 одной цепочки (`<тег> is needed on chain X position i
///   and on chain Y position j`).
///
/// Здесь — план, как собрать цепочки без этого:
/// - узел или группа, стоящие позицией сами, из групп других позиций этой
///   цепочки снимаются (копия группы без них);
/// - позиция ≥ 1 собирается из копии группы без всего, что достижимо ниже в
///   этой же цепочке (кольцо и конфликт внутри цепочки);
/// - узел или группа, занятые цепочкой выше по списку, берутся копией под
///   своим тегом; узел с собственной сессией (WireGuard/AWG, Tailscale и
///   прочие endpoint'ы) копией не разводится — копия с теми же ключами
///   остаётся одной сессией на два пути, такая цепочка выпадает;
/// - остальное неисправимое (позиция целиком стоит ниже, группа опустела,
///   кольцо через `detour`, вложенная цепочка выше позиции 0, занятый тег
///   хопа) — цепочка выпадает.
///
/// Чистая функция над картой тел: её зовут сборка ([planChainTakeover] →
/// `applyChainTakeover`) и форма цепочки (та же проверка по последнему
/// собранному конфигу).
library;

const _kGroupTypes = {'selector', 'urltest'};
const _kNoPath = {'direct', 'block', 'dns'};

/// Типы узлов с собственной сессией: копия с теми же ключами — та же сессия.
/// Любой узел секции `endpoints` — тоже.
const Set<String> kChainSessionTypes = {
  'wireguard',
  'amneziawg',
  'tailscale',
  'openconnect',
  'openvpn-client',
};

/// Почему цепочка не собирается.
enum ChainTakeoverFault {
  /// Позиция целиком достижима ниже в той же цепочке.
  positionBelow,

  /// Группа на позиции опустела: все её узлы стоят ниже.
  groupEmptied,

  /// Узел с собственной сессией нужен и другой цепочке.
  sessionShared,

  /// Собственный `detour` узла позиции 0 ведёт в узел позиции выше.
  detourRing,

  /// Вложенная цепочка выше позиции 0.
  nestedChain,

  /// Тег хопа `<цепочка>#<i>` занят узлом или группой конфига.
  hopTagTaken,

  /// Позиция повторяется.
  duplicate,
}

/// Отказ одной цепочки. [position] — с 0; [tag] — узел/группа; [other] —
/// вторая цепочка ([ChainTakeoverFault.sessionShared]) или цель `detour`
/// ([ChainTakeoverFault.detourRing]).
class ChainTakeoverFailure {
  const ChainTakeoverFailure({
    required this.chain,
    required this.fault,
    required this.position,
    required this.tag,
    this.other = '',
  });

  final String chain;
  final ChainTakeoverFault fault;
  final int position;
  final String tag;
  final String other;

  /// EN-строка для `emitWarnings` (позиция с 1, как в прочих строках цепочек).
  String get warning {
    final at = 'position ${position + 1}';
    final head = 'Hop chain "$chain" was dropped: ';
    return head +
        switch (fault) {
          ChainTakeoverFault.positionBelow =>
            '"$tag" at $at is already reached at a lower position of the same '
                'chain — one node or group has one path.',
          ChainTakeoverFault.groupEmptied =>
            'group "$tag" at $at has no nodes left after removing those that '
                'stand lower in the chain.',
          ChainTakeoverFault.sessionShared =>
            'node "$tag" at $at is also used by chain "$other"; it holds its '
                'own session and cannot be copied for a second path.',
          ChainTakeoverFault.detourRing =>
            'the detour of "$tag" at position 1 leads to "$other", which the '
                'chain takes over higher up — that makes a ring.',
          ChainTakeoverFault.nestedChain =>
            'nested chain "$tag" at $at — a nested chain is only allowed at '
                'position 1.',
          ChainTakeoverFault.hopTagTaken =>
            'the tag "$tag" is taken by a node or group; the core needs it for '
                'the chain\'s hop.',
          ChainTakeoverFault.duplicate =>
            '"$tag" is used more than once — one node or group has one path.',
        };
  }
}

/// Новый объект конфига: копия узла или группы.
typedef ChainCopy = ({String section, Map<String, dynamic> body});

/// План одной цепочки: финальные позиции (теги копий там, где нужны) и копии.
class ChainTakeoverPlan {
  const ChainTakeoverPlan({
    required this.chain,
    required this.positions,
    required this.copies,
  });

  final String chain;
  final List<String> positions;
  final List<ChainCopy> copies;
}

/// Итог по всем цепочкам.
class ChainTakeoverResult {
  const ChainTakeoverResult({required this.plans, required this.failures});

  final List<ChainTakeoverPlan> plans;
  final List<ChainTakeoverFailure> failures;
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

/// План цепочек [chains] (теги цепочек в порядке объявления) над [bodies].
/// Цепочка выше по списку держит оригиналы, ниже — получает копии.
/// [bodies] не меняется.
ChainTakeoverResult planChainTakeover(
  ChainBodies bodies,
  List<String> chains,
) {
  final taken = <String>{...bodies.keys};
  // Оригинальный тег → цепочка, которая его заняла.
  final claimed = <String, String>{};
  final plans = <ChainTakeoverPlan>[];
  final failures = <ChainTakeoverFailure>[];
  for (final chainTag in chains) {
    final chain = bodies[chainTag]?.body;
    final raw = chain?['outbounds'];
    if (chain == null || raw is! List) continue;
    final positions = [for (final p in raw) '$p'];
    final r = _planOne(chainTag, positions, bodies, claimed, taken);
    if (r.failure != null) {
      failures.add(r.failure!);
      continue;
    }
    plans.add(r.plan!);
    for (final t in r.reached) {
      claimed.putIfAbsent(t, () => chainTag);
    }
    for (final c in r.plan!.copies) {
      taken.add(c.body['tag'] as String);
    }
  }
  return ChainTakeoverResult(plans: plans, failures: failures);
}

class _Fail implements Exception {
  _Fail(this.failure);
  final ChainTakeoverFailure failure;
}

({ChainTakeoverPlan? plan, ChainTakeoverFailure? failure, Set<String> reached})
    _planOne(
  String chainTag,
  List<String> positions,
  ChainBodies bodies,
  Map<String, String> claimed,
  Set<String> takenTags,
) {
  ChainTakeoverFailure fail(ChainTakeoverFault f, int i, String tag,
          [String other = '']) =>
      ChainTakeoverFailure(
          chain: chainTag, fault: f, position: i, tag: tag, other: other);
  final none = <String>{};

  final seen = <String>{};
  for (var i = 0; i < positions.length; i++) {
    if (!seen.add(positions[i])) {
      return (
        plan: null,
        failure: fail(ChainTakeoverFault.duplicate, i, positions[i]),
        reached: none
      );
    }
  }
  for (var i = 0; i < positions.length; i++) {
    final hop = '$chainTag#$i';
    if (bodies.containsKey(hop)) {
      return (
        plan: null,
        failure: fail(ChainTakeoverFault.hopTagTaken, i, hop),
        reached: none
      );
    }
  }

  final copies = <ChainCopy>[];
  // Копия узла, уже сделанная в этой цепочке (узел встречен дважды на одной
  // позиции через разные группы).
  final copiedLeaf = <String, String>{};
  final localTaken = <String>{...takenTags};
  String copyTag(String orig) {
    var t = '$orig · $chainTag';
    for (var n = 2; localTaken.contains(t); n++) {
      t = '$orig · $chainTag $n';
    }
    localTaken.add(t);
    return t;
  }

  // Оригинальные теги, достижимые на позициях ниже текущей.
  final below = <String>{};
  // Теги, стоящие позицией сами: группы других позиций их не берут
  // (`[Направление{A, X}, A]` — внизу копия Направления без A).
  final explicit = positions.toSet();
  // Финальные теги (с копиями) позиций ≥ 1 — для кольца через detour.
  final upperFinal = <String>{};
  final newPositions = <String>[];
  final reachedAll = <String>{};

  for (var i = 0; i < positions.length; i++) {
    final p = positions[i];
    final entry = bodies[p];
    if (entry == null) {
      // Висячую позицию судит граф-санитайзер сборки.
      newPositions.add(p);
      continue;
    }
    final type = entry.body['type'];
    if (type == 'chain') {
      if (i >= 1) {
        return (
          plan: null,
          failure: fail(ChainTakeoverFault.nestedChain, i, p),
          reached: none
        );
      }
      newPositions.add(p);
      continue;
    }
    if (i >= 1 && below.contains(p)) {
      return (
        plan: null,
        failure: fail(ChainTakeoverFault.positionBelow, i, p),
        reached: none
      );
    }
    final reached = <String>{};
    final finals = <String>{};
    String? rebuild(String tag, Set<String> visiting) {
      final e = bodies[tag];
      if (e == null) return tag;
      final t = e.body['type'];
      if (_kNoPath.contains(t) || t == 'chain') return tag;
      if (below.contains(tag)) return null;
      if (tag != p && explicit.contains(tag)) return null;
      if (!visiting.add(tag)) return tag;
      final owner = claimed[tag];
      if (_kGroupTypes.contains(t)) {
        final members = e.body['outbounds'];
        final list = members is List ? [for (final m in members) '$m'] : <String>[];
        final mapped = <String, String>{};
        final kept = <String>[];
        for (final m in list) {
          final r = rebuild(m, visiting);
          if (r == null) continue;
          mapped[m] = r;
          kept.add(r);
        }
        visiting.remove(tag);
        if (kept.isEmpty) {
          if (tag == p) throw _Fail(fail(ChainTakeoverFault.groupEmptied, i, p));
          return null;
        }
        reached.add(tag);
        final changed = owner != null ||
            kept.length != list.length ||
            [for (var k = 0; k < list.length; k++) list[k] != kept[k]]
                .any((x) => x);
        if (!changed) {
          finals.add(tag);
          return tag;
        }
        final nt = copyTag(tag);
        final copy = <String, dynamic>{...e.body, 'tag': nt, 'outbounds': kept};
        final def = e.body['default'];
        if (def is String) {
          final md = mapped[def];
          if (md != null) {
            copy['default'] = md;
          } else {
            copy.remove('default');
          }
        }
        copies.add((section: e.section, body: copy));
        finals.add(nt);
        return nt;
      }
      visiting.remove(tag);
      reached.add(tag);
      if (owner == null) {
        finals.add(tag);
        return tag;
      }
      if (e.section == 'endpoints' || kChainSessionTypes.contains(t)) {
        throw _Fail(fail(ChainTakeoverFault.sessionShared, i, tag, owner));
      }
      final prev = copiedLeaf[tag];
      if (prev != null) return prev;
      final nt = copiedLeaf[tag] = copyTag(tag);
      copies.add((
        section: e.section,
        body: {...e.body, 'tag': nt},
      ));
      finals.add(nt);
      return nt;
    }

    try {
      final r = rebuild(p, <String>{});
      if (r == null) {
        return (
          plan: null,
          failure: fail(ChainTakeoverFault.groupEmptied, i, p),
          reached: none
        );
      }
      newPositions.add(r);
    } on _Fail catch (f) {
      return (plan: null, failure: f.failure, reached: none);
    }
    below.addAll(reached);
    reachedAll.addAll(reached);
    if (i >= 1) upperFinal.addAll(finals);
  }

  // Кольцо через detour: узел позиции 0 идёт своим путём, и если этот путь
  // (detour и члены групп по нему) заходит в узел позиции выше — кольцо.
  if (newPositions.isNotEmpty && upperFinal.isNotEmpty) {
    final copyBodies = {
      for (final c in copies) c.body['tag'] as String: c.body,
    };
    Map<String, dynamic>? bodyOf(String t) =>
        copyBodies[t] ?? bodies[t]?.body;
    final entryLeaves = <String>{};
    void leaves(String t, Set<String> seen) {
      if (!seen.add(t)) return;
      final b = bodyOf(t);
      if (b == null) return;
      if (_kGroupTypes.contains(b['type'])) {
        for (final m in (b['outbounds'] as List? ?? const [])) {
          leaves('$m', seen);
        }
      } else if (!_kNoPath.contains(b['type']) && b['type'] != 'chain') {
        entryLeaves.add(t);
      }
    }

    leaves(newPositions.first, <String>{});
    for (final leaf in entryLeaves) {
      final start = bodyOf(leaf)?['detour'];
      if (start is! String) continue;
      final queue = [start];
      final visited = <String>{};
      while (queue.isNotEmpty) {
        final t = queue.removeLast();
        if (!visited.add(t)) continue;
        if (upperFinal.contains(t)) {
          return (
            plan: null,
            failure: fail(ChainTakeoverFault.detourRing, 0, leaf, t),
            reached: none
          );
        }
        final b = bodyOf(t);
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

  return (
    plan: ChainTakeoverPlan(
        chain: chainTag, positions: newPositions, copies: copies),
    failure: null,
    reached: reachedAll,
  );
}

/// Сборка: применить план к [config] — копии в свои секции, позиции цепочек
/// на теги копий, выпавшие цепочки сняты из `outbounds` (ссылки на них
/// дочищает граф-санитайзер). Возвращает строки для `emitWarnings`.
List<String> applyChainTakeover(Map<String, dynamic> config) {
  final bodies = chainBodiesOf(config);
  final chains = [
    for (final e in bodies.entries)
      if (e.value.body['type'] == 'chain') e.key,
  ];
  if (chains.isEmpty) return const [];
  final result = planChainTakeover(bodies, chains);
  final warnings = <String>[];
  final droppedTags = {for (final f in result.failures) f.chain};
  for (final f in result.failures) {
    warnings.add(f.warning);
  }
  if (droppedTags.isNotEmpty) {
    final list = config['outbounds'];
    if (list is List) {
      list.removeWhere((e) => e is Map && droppedTags.contains(e['tag']));
    }
  }
  for (final plan in result.plans) {
    if (plan.copies.isEmpty) {
      continue;
    }
    bodies[plan.chain]!.body['outbounds'] = plan.positions;
    for (final c in plan.copies) {
      final list = config[c.section];
      if (list is List) {
        list.add(c.body);
      } else {
        config[c.section] = [c.body];
      }
    }
  }
  return warnings;
}
