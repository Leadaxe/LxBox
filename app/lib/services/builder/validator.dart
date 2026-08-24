import '../../models/validation.dart';

/// §254 — сколько detour-виновников показывать максимум. Юзер чинит первые,
/// пересобирает, видит следующие. Кап рубит квадратичную окраску на
/// патологическом конфиге (много нод, каждая замыкает свой цикл).
const kMaxDetourCulprits = 3;

/// Валидация собранного конфига (§3.5 спеки 026). Функция, не класс.
///
/// Проверяет:
/// - `route.rules[].outbound` / `route.final` ссылаются на существующий tag →
///   иначе `DanglingOutboundRef` (fatal). §219.
/// - `outbounds[]/endpoints[].detour` ссылается на существующий tag → иначе
///   `DanglingDetourRef` (fatal). §084 H1.
/// - `outbounds[type=urltest]` не пуст → иначе `EmptyUrltestGroup` (fatal).
/// - `outbounds[type=selector].default` в options → иначе `InvalidDefault`
///   (fatal).
/// - `dns.final` / `route.default_domain_resolver` ссылаются на существующий
///   `dns.servers[].tag` → иначе `DanglingDnsServerRef` (fatal). §121.
ValidationResult validateConfig(Map<String, dynamic> config) {
  final issues = <ValidationIssue>[];

  final outbounds = (config['outbounds'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  final endpoints = (config['endpoints'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();

  final allTags = <String>{
    for (final o in outbounds) o['tag'] as String? ?? '',
    for (final e in endpoints) e['tag'] as String? ?? '',
  }..remove('');

  // Rule → outbound references.
  final rules = (config['route']?['rules'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>();
  var ruleIdx = 0;
  for (final r in rules) {
    final outRef = r['outbound'];
    if (outRef is String && outRef.isNotEmpty && !allTags.contains(outRef)) {
      issues.add(DanglingOutboundRef('rules[$ruleIdx]', outRef));
    }
    ruleIdx++;
  }

  // §219 — `route.final` → существующий outbound-tag. Симметрично проверке
  // `route.rules[].outbound` выше и `dns.final` ниже. build_config деградирует
  // dangling route_final до vpn-1, но validator обязан ловить его независимо от
  // порядка post-steps (напр. при ручном редактировании JSON): битый route.final
  // роняет старт ядра.
  final routeFinal = config['route']?['final'];
  if (routeFinal is String &&
      routeFinal.isNotEmpty &&
      !allTags.contains(routeFinal)) {
    issues.add(DanglingOutboundRef('route.final', routeFinal));
  }

  // §084 H1 — detour references (outbounds + endpoints) → existing tag.
  // §141 P1.8a — заодно собираем рёбра detour-графа (tag → detour) для
  // последующей проверки на циклы. В граф кладём только рёбра на СУЩЕСТВУЮЩИЙ
  // tag — dangling уже зарепорчен отдельно, и цикл может состоять лишь из
  // живых узлов.
  final detourEdge = <String, String>{};
  for (final o in [...outbounds, ...endpoints]) {
    final detour = o['detour'];
    if (detour is! String || detour.isEmpty) continue;
    final owner = o['tag'] as String? ?? '';
    if (!allTags.contains(detour)) {
      issues.add(DanglingDetourRef(owner, detour));
    } else if (owner.isNotEmpty) {
      detourEdge[owner] = detour;
    }
  }

  // §141 P1.8a / §254 — циклы в detour-графе. Граф включает структурные
  // рёбра «группа → каждый член» (selector/urltest): ядро при топосортировке
  // старта считает так же (selector объявляет зависимостями ВСЕХ членов), и
  // без них кольцо через Направление ([BL]→vpn-5→AWG→vpn-4→[BL]) невидимо для
  // чистых node→detour цепочек. Один issue на цикл-компоненту, с минимальным
  // набором виновников (§254 — ничего не правим, юзер устраняет сам).
  final groupMembers = <String, List<String>>{};
  for (final o in outbounds) {
    final type = o['type'] as String? ?? '';
    if (type != 'selector' && type != 'urltest') continue;
    final tag = o['tag'] as String? ?? '';
    if (tag.isEmpty) continue;
    final members = (o['outbounds'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .where(allTags.contains)
        .toList();
    if (members.isNotEmpty) groupMembers[tag] = members;
  }
  issues.addAll(
    _detectDetourCycles(detourEdge: detourEdge, groupMembers: groupMembers),
  );

  // §121 — DNS resolver refs → existing dns.servers tag.
  final dns = config['dns'];
  final dnsServerTags = <String>{
    for (final s
        in (dns?['servers'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>())
      s['tag'] as String? ?? '',
  }..remove('');
  final dnsFinal = dns?['final'];
  if (dnsFinal is String &&
      dnsFinal.isNotEmpty &&
      !dnsServerTags.contains(dnsFinal)) {
    issues.add(DanglingDnsServerRef('dns.final', dnsFinal));
  }
  final domainResolver = config['route']?['default_domain_resolver'];
  if (domainResolver is String &&
      domainResolver.isNotEmpty &&
      !dnsServerTags.contains(domainResolver)) {
    issues.add(
      DanglingDnsServerRef('route.default_domain_resolver', domainResolver),
    );
  }

  // §312 — DNS-группы (kernel SPEC 033): пустая после эмиссионного фильтра /
  // недопустимый тип члена (fakeip/hosts) / циклы групп. Всё зеркалит fatal'ы
  // ядра — падаем ДО старта (§254-принцип). Dangling-члены здесь НЕ ловим:
  // билдер их уже выкинул с warning'ом (drop-семантика §312 №3).
  final dnsServerList = (dns?['servers'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  final dnsTypeByTag = <String, String>{
    for (final s in dnsServerList)
      if (s['tag'] is String && (s['tag'] as String).isNotEmpty)
        s['tag'] as String: s['type'] as String? ?? '',
  };
  // §384 — тип сервера под resolver-ссылками. Проверка ссылок выше отвечает
  // лишь на «тег существует»; ядро дополнительно запрещает тут fakeip/hosts
  // (`default server cannot be fakeip`). Считаем здесь, где карта типов уже
  // построена. Dangling-случай сюда не попадает — тега нет в карте.
  for (final ref in <(String, Object?)>[
    ('dns.final', dnsFinal),
    ('route.default_domain_resolver', domainResolver),
  ]) {
    final (field, value) = ref;
    if (value is! String || value.isEmpty) continue;
    final type = dnsTypeByTag[value];
    if (type == 'fakeip' || type == 'hosts') {
      issues.add(BadResolverServerType(field, value, type!));
    }
  }

  final dnsGroupEdges = <String, List<String>>{};
  for (final s in dnsServerList) {
    if (s['type'] != 'group') continue;
    final tag = s['tag'] as String? ?? '';
    if (tag.isEmpty) continue;
    final members = (s['servers'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList();
    if (members.isEmpty) {
      issues.add(EmptyDnsGroup(tag));
      continue;
    }
    for (final m in members) {
      final mt = dnsTypeByTag[m];
      if (mt == 'fakeip' || mt == 'hosts') {
        issues.add(BadDnsGroupMember(tag, m, mt!));
      }
    }
    // Рёбра цикл-графа: только члены-ГРУППЫ (лист цикл не образует).
    dnsGroupEdges[tag] = [
      for (final m in members)
        if (dnsTypeByTag[m] == 'group') m,
    ];
  }
  issues.addAll(_findDnsGroupCycles(dnsGroupEdges));

  // Empty urltest + invalid selector default.
  for (final o in outbounds) {
    final type = o['type'] as String? ?? '';
    final tag = o['tag'] as String? ?? '';
    final opts = (o['outbounds'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList();
    if (type == 'urltest' && opts.isEmpty) {
      issues.add(EmptyUrltestGroup(tag));
    }
    if (type == 'selector') {
      final def = o['default'];
      // §141 P1.8b — ловим и не-строковый `default` (sing-box ждёт строку-тег;
      // число/bool ⇒ фейл-старт ядра). Симметрично гейту в build_config.
      if (def != null && (def is! String || !opts.contains(def))) {
        issues.add(InvalidDefault(tag, def.toString()));
      }
    }
  }

  return ValidationResult(issues);
}

/// §254 — детектор detour-циклов с минимальным набором виновников.
///
/// Граф: removable-рёбра `node → node.detour` (устранимы правкой юзера) +
/// структурные `группа → каждый член` (semantика selector/urltest,
/// устранению не подлежат). Циклы ищутся SCC (итеративный Tarjan);
/// виновники — итеративной окраской:
///
/// 1. Найти циклические узлы (SCC >1 или self-loop). Нет — конец.
/// 2. Кандидаты = removable-рёбра внутри циклического множества.
/// 3. score(e) = сколько узлов перестают быть циклическими при виртуальном
///    снятии e. Ребро, через которое идут ВСЕ циклы компоненты, разваливает
///    её целиком → max score (в реальном кейсе: 1 нода против 150 членов
///    Направления, см. spec 254).
/// 4. Победитель (тай-брейк — лексикографически по тегу) виртуально
///    снимается; повторить с шага 1 — «обнажившиеся» кольца ловятся
///    следующей итерацией.
///
/// Виновники группируются по цикл-компонентам ИСХОДНОГО графа: один
/// [DetourCycle] на компоненту, с репрезентативным циклом (кратчайшее
/// замыкание первого виновника) для раскрытия в UI.
List<DetourCycle> _detectDetourCycles({
  required Map<String, String> detourEdge,
  required Map<String, List<String>> groupMembers,
}) {
  final nodes = <String>{
    ...detourEdge.keys,
    ...detourEdge.values,
    ...groupMembers.keys,
    for (final ms in groupMembers.values) ...ms,
  };
  if (nodes.isEmpty) return const [];

  final initialCyclic = _cyclicNodes(nodes, detourEdge, groupMembers, const {});
  if (initialCyclic.isEmpty) return const [];

  // §254 — показываем не больше [kMaxDetourCulprits] виновников: юзер чинит
  // первые, пересобирает, видит следующие. Заодно кап рубит квадратичную
  // окраску на патологическом конфиге (150 нод, каждая детурит в свой канал:
  // без капа 150 итераций × ~150 кандидатов × Tarjan ≈ 1.3с внутри
  // generateConfig). structuralIssues копятся отдельно.
  final removed = <String>{};
  final culprits = <String>[];
  final structuralCycles = <List<String>>[];
  while (culprits.length < kMaxDetourCulprits) {
    final cyclic = _cyclicNodes(nodes, detourEdge, groupMembers, removed);
    if (cyclic.isEmpty) break;
    final candidates =
        detourEdge.keys
            .where(
              (u) =>
                  !removed.contains(u) &&
                  cyclic.contains(u) &&
                  cyclic.contains(detourEdge[u]),
            )
            .toList()
          ..sort();
    var best = candidates.isEmpty ? null : candidates.first;
    var bestScore = 0;
    for (final u in candidates) {
      final after = _cyclicNodes(nodes, detourEdge, groupMembers, {
        ...removed,
        u,
      });
      final score = cyclic.length - after.length;
      if (score > bestScore) {
        bestScore = score;
        best = u;
      }
    }
    if (best == null || bestScore <= 0) {
      // Ни одно removable-ребро не лежит на цикле (кольцо из structural-рёбер
      // selector↔selector — только ручная правка JSON; либо мост-ребро вне
      // цикла). Виновников-нод нет: репортим эту компоненту как group-only
      // цикл и снимаем её из графа, чтобы не зациклиться (structural-рёбра
      // неустранимы → удаляем узлы компоненты из дальнейшего рассмотрения).
      structuralCycles.add(cyclic.toList()..sort());
      break;
    }
    removed.add(best);
    culprits.add(best);
  }

  // Группировка виновников по компонентам исходного графа: BFS-достижимость
  // внутри initialCyclic (SCC-компонента = взаимодостижимость; для
  // группировки хватает слабой связности внутри циклического множества —
  // разные SCC, слитые в одну слабую компоненту detour-мостом, дадут один
  // общий issue, что для UI даже читабельнее).
  final undirected = <String, Set<String>>{};
  void link(String a, String b) {
    if (!initialCyclic.contains(a) || !initialCyclic.contains(b)) return;
    (undirected[a] ??= {}).add(b);
    (undirected[b] ??= {}).add(a);
  }

  for (final e in detourEdge.entries) {
    link(e.key, e.value);
  }
  for (final g in groupMembers.entries) {
    for (final m in g.value) {
      link(g.key, m);
    }
  }

  final componentOf = <String, int>{};
  var compId = 0;
  for (final start in initialCyclic) {
    if (componentOf.containsKey(start)) continue;
    final queue = [start];
    componentOf[start] = compId;
    while (queue.isNotEmpty) {
      final u = queue.removeLast();
      for (final v in undirected[u] ?? const <String>{}) {
        if (componentOf.containsKey(v)) continue;
        componentOf[v] = compId;
        queue.add(v);
      }
    }
    compId++;
  }

  final byComponent = <int, List<String>>{};
  for (final c in culprits) {
    (byComponent[componentOf[c] ?? -1] ??= []).add(c);
  }

  return [
    for (final group in byComponent.values)
      DetourCycle(
        _representativeCycle(group.first, detourEdge, groupMembers),
        culprits: [
          for (final tag in group) (tag: tag, detour: detourEdge[tag]!),
        ],
      ),
    // Group-only кольца (structural-рёбра, ручная правка JSON): виновников-нод
    // нет, показываем сам цикл. Отдельным issue каждое — не склеиваем.
    for (final cycle in structuralCycles) DetourCycle(cycle),
  ];
}

/// Циклические узлы графа: итеративный Tarjan SCC; циклична SCC размера >1
/// либо одиночный узел с self-loop.
Set<String> _cyclicNodes(
  Set<String> nodes,
  Map<String, String> detourEdge,
  Map<String, List<String>> groupMembers,
  Set<String> removed,
) {
  List<String> adjOf(String u) => [
    ...?groupMembers[u],
    if (!removed.contains(u) && detourEdge.containsKey(u)) detourEdge[u]!,
  ];

  final index = <String, int>{};
  final low = <String, int>{};
  final onStack = <String>{};
  final stack = <String>[];
  final cyclic = <String>{};
  var counter = 0;

  for (final root in nodes) {
    if (index.containsKey(root)) continue;
    // Итеративный DFS: (узел, позиция в adjacency).
    final work = <(String, int)>[(root, 0)];
    while (work.isNotEmpty) {
      final (v, pi) = work.last;
      if (pi == 0) {
        index[v] = low[v] = counter++;
        stack.add(v);
        onStack.add(v);
      }
      var recursed = false;
      final adj = adjOf(v);
      for (var i = pi; i < adj.length; i++) {
        final w = adj[i];
        if (!index.containsKey(w)) {
          work.last = (v, i + 1);
          work.add((w, 0));
          recursed = true;
          break;
        } else if (onStack.contains(w)) {
          low[v] = low[v]!.compareTo(index[w]!) < 0 ? low[v]! : index[w]!;
        }
      }
      if (recursed) continue;
      if (low[v] == index[v]) {
        final comp = <String>[];
        while (true) {
          final w = stack.removeLast();
          onStack.remove(w);
          comp.add(w);
          if (w == v) break;
        }
        if (comp.length > 1) {
          cyclic.addAll(comp);
        } else if (adjOf(comp.single).contains(comp.single)) {
          cyclic.add(comp.single); // self-loop
        }
      }
      work.removeLast();
      if (work.isNotEmpty) {
        final (u, upi) = work.last;
        low[u] = low[u]!.compareTo(low[v]!) < 0 ? low[u]! : low[v]!;
        work.last = (u, upi);
      }
    }
  }
  return cyclic;
}

/// Репрезентативный цикл для виновника: BFS кратчайший путь от его detour-цели
/// обратно к нему + само ребро. Формат — теги в порядке обхода (последний
/// замыкает на первый): `[culprit, detour, ..., предшественник culprit]`.
List<String> _representativeCycle(
  String culprit,
  Map<String, String> detourEdge,
  Map<String, List<String>> groupMembers,
) {
  final target = detourEdge[culprit]!;
  if (target == culprit) return [culprit]; // self-loop
  final prev = <String, String>{};
  final queue = [target];
  final seen = <String>{target};
  while (queue.isNotEmpty) {
    final u = queue.removeAt(0);
    if (u == culprit) break;
    final adj = [
      ...?groupMembers[u],
      if (detourEdge.containsKey(u)) detourEdge[u]!,
    ];
    for (final v in adj) {
      if (!seen.add(v)) continue;
      prev[v] = u;
      queue.add(v);
    }
  }
  // Раскрутка пути target..culprit; цикл начинается с culprit.
  final path = <String>[];
  String? cur = culprit;
  while (cur != null && cur != target) {
    path.add(cur);
    cur = prev[cur];
  }
  path.add(target);
  // path = [culprit, ..., target] в обратном порядке следования; развернём в
  // порядок обхода: culprit → target → ... → предшественник culprit.
  return [culprit, ...path.reversed.where((t) => t != culprit)];
}

/// §312 — циклы в графе DNS-групп (рёбра «группа → член-группа»). Рекурсивный
/// DFS с path-стеком (глубина = число групп, единицы); один [DnsGroupCycle] на
/// цикл-компоненту (узлы найденного цикла глушатся, чтобы не сыпать дубли
/// того же кольца с разных входов). Правки конфига нет — юзер устраняет сам
/// (§254-принцип).
List<DnsGroupCycle> _findDnsGroupCycles(Map<String, List<String>> edges) {
  final issues = <DnsGroupCycle>[];
  final done = <String>{}; // полностью обработанные / в зарепорченном цикле
  for (final start in edges.keys) {
    if (done.contains(start)) continue;
    final onPath = <String>[]; // текущий путь DFS (для вырезки цикла)
    final visitedLocal = <String>{};
    void dfs(String u) {
      if (done.contains(u)) return;
      final idx = onPath.indexOf(u);
      if (idx != -1) {
        // Нашли кольцо: срез пути от первого вхождения u.
        final cycle = onPath.sublist(idx);
        issues.add(DnsGroupCycle(List<String>.unmodifiable(cycle)));
        done.addAll(cycle);
        return;
      }
      if (!visitedLocal.add(u)) return;
      onPath.add(u);
      for (final v in (edges[u] ?? const [])) {
        dfs(v);
      }
      onPath.removeLast();
    }

    dfs(start);
    done.add(start);
  }
  return issues;
}
