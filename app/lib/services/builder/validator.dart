import '../../models/validation.dart';

/// Валидация собранного конфига (§3.5 спеки 026). Функция, не класс.
///
/// Проверяет:
/// - `route.rules[].outbound` ссылается на существующий tag → иначе
///   `DanglingOutboundRef` (fatal).
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

  // §141 P1.8a — цикл в detour-графе (3-цветный DFS). Каждый узел имеет ≤1
  // исходящего detour-ребра, так что граф — набор цепочек/деревьев; цикл =
  // ребро обратно в текущий путь обхода (gray). Первый найденный цикл —
  // достаточный сигнал fatal (один битый detour ломает старт ядра).
  final cycle = _findDetourCycle(detourEdge);
  if (cycle != null) {
    issues.add(DetourCycle(cycle));
  }

  // §121 — DNS resolver refs → existing dns.servers tag.
  final dns = config['dns'];
  final dnsServerTags = <String>{
    for (final s in (dns?['servers'] as List<dynamic>? ?? const [])
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
        DanglingDnsServerRef('route.default_domain_resolver', domainResolver));
  }

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

/// §141 P1.8a — поиск первого цикла в detour-графе. `edges`: tag → его detour
/// (ровно одно исходящее ребро на узел). Возвращает список тегов цикла в
/// порядке обхода (последний замыкает на первый) либо `null`, если циклов нет.
///
/// 3-цветный обход: `done` — узлы, из которых цикл точно недостижим (уже
/// раскрученная цепочка); `path` — узлы текущего следования по ребрам. Встретив
/// узел из `path`, отрезаем хвост от него — это и есть цикл (ловит и self-ref
/// `A→A`, где `start == detour`).
List<String>? _findDetourCycle(Map<String, String> edges) {
  final done = <String>{};
  for (final start in edges.keys) {
    if (done.contains(start)) continue;
    final path = <String>[];
    final seenInPath = <String>{};
    var node = start;
    while (true) {
      if (done.contains(node)) break; // уперлись в безопасную раскрутку
      if (seenInPath.contains(node)) {
        // Нашли цикл — вернуть его, отрезав возможный «хвост-подход».
        final from = path.indexOf(node);
        return path.sublist(from);
      }
      seenInPath.add(node);
      path.add(node);
      final next = edges[node];
      if (next == null) break; // конец цепочки — циклов на этом пути нет
      node = next;
    }
    done.addAll(path); // вся пройденная цепочка цикла не содержит
  }
  return null;
}
