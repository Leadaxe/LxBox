/// §757 — выпуск правила-дерева: наборы `route.rule_set`, маршрутное и
/// resolve-правило, DNS-зеркало по дереву (TEMPLATE_LANG §6.13, §6.11;
/// контракт 1.1.179, TASKS_LXBOX §182 п. 2.3–2.5).
///
/// Чистые функции. Какие ключи идут в набор (`set`) и в зеркало (`dns`),
/// какие доменные (`group: domain`) — из таблицы условий реестра
/// ([RuleConditionTable]); имён ключей условий здесь нет.
///
/// Волна B: подключено к сборке (`post_steps/custom_rules.dart`).
library;

import '../../models/custom_rule.dart' show RuleDns, RuleResolve;
import '../../models/rule_tree.dart';
import '../contract/rule_conditions.dart';
import 'post_steps.dart' show DnsMirrorEntry, kFixedIpAnswerTtl;
import 'rule_tree_tags.dart';

/// §757 — inline-набор, выпущенный у узла.
final class RuleTreeInlineSet {
  const RuleTreeInlineSet({
    required this.tag,
    required this.path,
    required this.nodeHasRefs,
    required this.keys,
  });

  final String tag;

  /// Путь узла ([ruleTreePath]; корень — пусто).
  final String path;

  /// У узла есть `refs` — набор обязателен по норме; нет — выбор стороны
  /// (§6.13 п. 4).
  final bool nodeHasRefs;

  /// Ключи, ушедшие в набор.
  final Map<String, Object> keys;
}

/// §757 — результат выпуска правила-дерева.
final class RuleTreeEmitResult {
  const RuleTreeEmitResult({
    this.ruleSets = const [],
    this.inlineSets = const [],
    this.match,
    this.routeRule,
    this.missingRefs = const [],
    this.warnings = const [],
  });

  /// Записи `route.rule_set` в порядке выпуска (pre-order: ссылки узла по
  /// `refs`, затем его inline-набор; одна ссылка — одна запись).
  final List<Map<String, dynamic>> ruleSets;

  /// Inline-наборы узлов (подмножество [ruleSets] с метаданными).
  final List<RuleTreeInlineSet> inlineSets;

  /// Выпущенное тело без цели — матч для маршрута, resolve и зеркала.
  final Map<String, dynamic>? match;

  /// Маршрутное правило: [match] + цель корня.
  final Map<String, dynamic>? routeRule;

  /// Ссылки без файла — правило не выпускается (всё или ничего, §6.13).
  final List<String> missingRefs;

  final List<String> warnings;

  /// Правило выпускается.
  bool get emitted => routeRule != null;
}

/// §757 — формат набора по расширению ссылки (TASKS_LXBOX §181 п. 1):
/// `.json` — `source`, иначе `binary`.
String ruleSetFormatOf(String ref) {
  final s = ref.trim();
  final path = Uri.tryParse(s)?.path ?? s;
  return path.toLowerCase().endsWith('.json') ? 'source' : 'binary';
}

/// §757 — выпуск правила-дерева.
///
/// [refPath] — путь скачанного файла ссылки или null. Нет файла хоть у
/// одной ссылки дерева — правило не выпускается ([RuleTreeEmitResult.emitted]
/// false, [RuleTreeEmitResult.missingRefs], предупреждение с именем).
/// [sideInlineSets] — выбор стороны §6.13 п. 4: ключи `set: true` узла без
/// `refs` тоже уводятся в inline-набор (в приложении включено).
///
/// Простое корневое правило без единого условия не выпускается: пустое
/// тело в ядре матчит весь трафик.
RuleTreeEmitResult emitRuleTree({
  required String ruleName,
  required RuleTreeBody body,
  required RuleTags tags,
  required String? Function(String ref) refPath,
  required RuleConditionTable table,
  bool sideInlineSets = true,
}) {
  final missing = [
    for (final r in ruleTreeRefs(body.root))
      if (refPath(r) == null) r,
  ];
  if (missing.isNotEmpty) {
    return RuleTreeEmitResult(
      missingRefs: missing,
      // Текст — прежний текст сборки для srs-правила без файла.
      warnings: [
        'SRS rule "$ruleName" skipped: no cached file (Download first).',
      ],
    );
  }
  final root = body.root;
  if (root is RuleLeaf &&
      root.conditions.isEmpty &&
      root.refs.isEmpty &&
      root.ruleSet.isEmpty) {
    return const RuleTreeEmitResult();
  }

  final ruleSets = <Map<String, dynamic>>[];
  final inlineSets = <RuleTreeInlineSet>[];
  final emittedRefTags = <String>{};

  Map<String, dynamic> emitLeaf(RuleLeaf leaf, List<int> path) {
    final node = <String, dynamic>{};
    final setTags = <String>[...leaf.ruleSet];
    for (final raw in leaf.refs) {
      final tag = tags.tagOfRef(raw)!;
      if (!setTags.contains(tag)) setTags.add(tag);
      if (emittedRefTags.add(tag)) {
        ruleSets.add({
          'type': 'local',
          'tag': tag,
          'format': ruleSetFormatOf(raw),
          'path': refPath(raw)!,
        });
      }
    }
    final rest = <String, Object>{};
    final setKeys = <String, Object>{};
    final hasSet = ruleLeafHasInlineSet(
      leaf,
      table,
      sideInlineSets: sideInlineSets,
    );
    for (final e in leaf.conditions.entries) {
      if (hasSet && (table.key(e.key)?.set ?? false)) {
        setKeys[e.key] = e.value;
      } else {
        rest[e.key] = e.value;
      }
    }
    if (hasSet) {
      final key = ruleTreePath(path);
      final tag = tags.inlineTags[key]!;
      setTags.add(tag);
      ruleSets.add({
        'type': 'inline',
        'tag': tag,
        'rules': [_copyMap(setKeys)],
      });
      inlineSets.add(
        RuleTreeInlineSet(
          tag: tag,
          path: key,
          nodeHasRefs: leaf.refs.isNotEmpty,
          keys: Map.unmodifiable(setKeys),
        ),
      );
    }
    if (setTags.isNotEmpty) {
      node[RuleConditionTable.kRuleSet] = setTags.length == 1
          ? setTags.first
          : setTags;
    }
    node.addAll(_copyMap(rest));
    if (leaf.invert) node[RuleConditionTable.kInvert] = true;
    return node;
  }

  Map<String, dynamic> emitNode(RuleNode n, List<int> path) => switch (n) {
    RuleLeaf() => emitLeaf(n, path),
    RuleGroup() => {
      RuleConditionTable.kType: RuleGroup.kLogical,
      RuleConditionTable.kMode: n.mode,
      RuleConditionTable.kRules: [
        for (var i = 0; i < n.children.length; i++)
          emitNode(n.children[i], [...path, i]),
      ],
      if (n.invert) RuleConditionTable.kInvert: true,
    },
  };

  final match = emitNode(root, const []);
  return RuleTreeEmitResult(
    ruleSets: ruleSets,
    inlineSets: inlineSets,
    match: match,
    routeRule: {..._deepCopy(match) as Map<String, dynamic>, ...body.target},
  );
}

/// §757 — рукописные теги `rule_set` дерева, которых нет в итоговом
/// `route.rule_set` ([finalRuleSetTags]). Непусто — правило, его наборы и
/// зеркала не выпускаются (§6.13 «Рукописный `rule_set`»). Постпроход:
/// итоговый список тегов известен только после всех правил.
Set<String> ruleTreeDanglingTags(RuleNode root, Set<String> finalRuleSetTags) =>
    {
      for (final (_, leaf) in ruleTreeLeaves(root))
        for (final t in leaf.ruleSet)
          if (!finalRuleSetTags.contains(t)) t,
    };

/// §757 — resolve-правило §247 над тем же деревом с теми же тегами:
/// `action: resolve` и непустые опции [r] у корня.
Map<String, dynamic> ruleTreeResolveRule(
  Map<String, dynamic> match,
  RuleResolve r,
) {
  final rule = _deepCopy(match) as Map<String, dynamic>;
  rule['action'] = 'resolve';
  // Пустое/null поле — ключ не выпускается (дефолты ядра), как у
  // `_resolveToRoute` плоского правила.
  if (r.strategy.isNotEmpty) rule['strategy'] = r.strategy;
  if (r.serverTag.isNotEmpty) rule['server'] = r.serverTag;
  if (r.disableCache) rule['disable_cache'] = true;
  if (r.disableOptimisticCache) rule['disable_optimistic_cache'] = true;
  if (r.rewriteTtl != null) rule['rewrite_ttl'] = r.rewriteTtl;
  if (r.timeout.isNotEmpty) rule['timeout'] = r.timeout;
  if (r.clientSubnet.isNotEmpty) rule['client_subnet'] = r.clientSubnet;
  return rule;
}

/// §757 — матчер DNS-зеркала `M` по выпущенному телу [match] (§6.11 «Зеркало
/// по дереву»). [inlineSets] — inline-наборы правила: набор без доменного
/// ключа исключается из `rule_set` зеркала. `null` — зеркало пусто.
Map<String, dynamic>? ruleTreeMirrorMatcher(
  Map<String, dynamic> match,
  List<RuleTreeInlineSet> inlineSets,
  RuleConditionTable table,
) {
  final noDomainTags = {
    for (final s in inlineSets)
      if (!s.keys.keys.any((k) => table.key(k)?.isDomain ?? false)) s.tag,
  };

  Map<String, dynamic>? walk(Map<String, dynamic> n) {
    final invert = n[RuleConditionTable.kInvert] == true;
    if (n[RuleConditionTable.kType] == RuleGroup.kLogical) {
      final kids = [
        for (final c in (n[RuleConditionTable.kRules] as List))
          ?walk(Map<String, dynamic>.from(c as Map)),
      ];
      if (kids.isEmpty) return null;
      if (kids.length == 1) {
        // Обёртка с одним ребёнком снимается: `invert` — по XOR.
        final child = kids.single;
        final inv = (child[RuleConditionTable.kInvert] == true) != invert;
        child.remove(RuleConditionTable.kInvert);
        if (inv) child[RuleConditionTable.kInvert] = true;
        return child;
      }
      return {
        RuleConditionTable.kType: RuleGroup.kLogical,
        RuleConditionTable.kMode: n[RuleConditionTable.kMode],
        RuleConditionTable.kRules: kids,
        if (invert) RuleConditionTable.kInvert: true,
      };
    }
    final out = <String, dynamic>{};
    final tags = [
      for (final t in _tagList(n[RuleConditionTable.kRuleSet]))
        if (!noDomainTags.contains(t)) t,
    ];
    if (tags.isNotEmpty) {
      out[RuleConditionTable.kRuleSet] = tags.length == 1 ? tags.first : tags;
    }
    for (final e in n.entries) {
      final desc = table.key(e.key);
      if (desc == null || !desc.dns || desc.isRefs) continue;
      if (!_nonZero(e.value)) continue;
      out[e.key] = _deepCopy(e.value);
    }
    // Узел, опустевший целиком, выбрасывается и под `invert`.
    if (out.isEmpty) return null;
    if (invert) out[RuleConditionTable.kInvert] = true;
    return out;
  }

  return walk(match);
}

/// §757 — зеркала правила-дерева.
final class RuleTreeMirrors {
  const RuleTreeMirrors({
    this.entries = const [],
    this.emptyWithDnsOption = false,
  });

  /// В порядке §6.11: Block HTTPS → глушилка AAAA → зеркало на сервер либо
  /// пара Fixed IP.
  final List<DnsMirrorEntry> entries;

  /// DNS-опция включена, а зеркало пустое (⚠ «DNS options have no effect…»).
  final bool emptyWithDnsOption;
}

/// §757 — DNS-опция правила включена (§6.11 «Пустое зеркало при включённой
/// опции»): `enabled` с `serverTag`, `forceIpv4`, `blockHttps`, `fixedIps`.
bool ruleDnsOptionOn(RuleDns? dns) =>
    dns != null &&
    ((dns.enabled && dns.serverTag.isNotEmpty) ||
        dns.forceIpv4 ||
        dns.blockHttps ||
        dns.fixedMode);

/// §757 — DNS-зеркала правила-дерева по §6.11.
///
/// Условия — геттеры `CustomRule` (`blockHttpsActive`, `forceIpv4Active`,
/// `dnsMirrorActive`, `dnsFixedActive`) с проверками по дереву вместо
/// плоских: `dnsLayerEligible` — [mirror] непуст; `hasDomainMatch` —
/// [hasRefsOrDomain] ([ruleTreeHasRefsOrDomain]). [enabled] — правило
/// включено (и выпущено в `route.rules`).
RuleTreeMirrors ruleTreeDnsMirrors({
  required String ruleId,
  required String ruleName,
  required bool enabled,
  required RuleDns? dns,
  required Map<String, dynamic>? mirror,
  required bool hasRefsOrDomain,
}) {
  if (dns == null) return const RuleTreeMirrors();
  if (mirror == null) {
    return RuleTreeMirrors(emptyWithDnsOption: ruleDnsOptionOn(dns));
  }
  if (!enabled) return const RuleTreeMirrors();
  final fixed = dns.fixedMode;
  final blockHttps = dns.blockHttps && hasRefsOrDomain;
  final forceIpv4 = dns.forceIpv4 && !fixed;
  final server = dns.enabled && dns.serverTag.isNotEmpty && !fixed;
  // §757 (контракт 1.1.180): в обёртку `and` идёт и простое `M` с
  // `invert` — иначе `query_type` / `ip_version` рядом попали бы под
  // отрицание (Block HTTPS глушил бы всё, кроме HTTPS доменов правила).
  final composite =
      mirror[RuleConditionTable.kType] == RuleGroup.kLogical ||
      mirror[RuleConditionTable.kInvert] == true;

  // Над составным `M` (или простым с `invert`) ключи условия действия — в
  // обёртке `and` (у корня `logical` ядро не принимает `query_type` /
  // `ip_version`); над простым без `invert` — рядом, как у плоских правил.
  Map<String, dynamic> withCondition(
    Map<String, dynamic> cond,
    Map<String, dynamic> action,
  ) {
    final m = _deepCopy(mirror) as Map<String, dynamic>;
    if (!composite) return {...m, ...cond, ...action};
    return {
      RuleConditionTable.kType: RuleGroup.kLogical,
      RuleConditionTable.kMode: RuleGroup.kAnd,
      RuleConditionTable.kRules: [m, cond],
      ...action,
    };
  }

  const predefined = {'action': 'predefined', 'rcode': 'NOERROR'};
  final out = <DnsMirrorEntry>[];
  if (blockHttps) {
    out.add(
      DnsMirrorEntry(
        ruleId: ruleId,
        ruleName: ruleName,
        serverless: true,
        blockHttps: true,
        body: withCondition({
          'query_type': ['HTTPS', 'SVCB'],
        }, predefined),
      ),
    );
  }
  if (forceIpv4) {
    out.add(
      DnsMirrorEntry(
        ruleId: ruleId,
        ruleName: ruleName,
        serverless: true,
        body: withCondition({'ip_version': 6}, predefined),
      ),
    );
  }
  if (fixed) {
    final v4 = <String>[];
    final v6 = <String>[];
    for (final ip in dns.fixedIps) {
      switch (RuleDns.ipRecordType(ip)) {
        case 'A':
          v4.add(ip.trim());
        case 'AAAA':
          v6.add(ip.trim());
      }
    }
    for (final (type, ips) in [('A', v4), ('AAAA', v6)]) {
      out.add(
        DnsMirrorEntry(
          ruleId: ruleId,
          ruleName: ruleName,
          serverless: true,
          fixedAnswer: true,
          body: withCondition(
            {
              'query_type': [type],
            },
            {
              ...predefined,
              if (ips.isNotEmpty)
                'answer': [
                  for (final ip in ips) '*. $kFixedIpAnswerTtl IN $type $ip',
                ],
            },
          ),
        ),
      );
    }
  } else if (server) {
    // Сервер — на корне `M` без обёртки (подставляет `dnsMirrorRule`).
    out.add(
      DnsMirrorEntry(
        ruleId: ruleId,
        ruleName: ruleName,
        serverTag: dns.serverTag,
        body: _deepCopy(mirror) as Map<String, dynamic>,
      ),
    );
  }
  return RuleTreeMirrors(entries: out);
}

List<String> _tagList(Object? v) => switch (v) {
  final String s => [s],
  final List l => l.whereType<String>().toList(),
  _ => const [],
};

bool _nonZero(Object? v) => switch (v) {
  null || false => false,
  final List l => l.isNotEmpty,
  final String s => s.isNotEmpty,
  _ => true,
};

Map<String, dynamic> _copyMap(Map<String, Object> m) => {
  for (final e in m.entries) e.key: _deepCopy(e.value),
};

Object? _deepCopy(Object? v) => switch (v) {
  final Map m => <String, dynamic>{
    for (final e in m.entries) e.key as String: _deepCopy(e.value),
  },
  final List l => [for (final e in l) _deepCopy(e)],
  _ => v,
};
