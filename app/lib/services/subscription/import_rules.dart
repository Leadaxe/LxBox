import '../../models/import_rule.dart';
import '../../models/node_spec.dart';
import '../../models/template_vars.dart';

/// §302 — применение import-rules к УЖЕ РАЗОБРАННЫМ узлам подписки.
///
/// Правила работают над каноническим sing-box JSON узла (`NodeSpec.emit`), а
/// не над текстом тела: `emit` одинаков для всех форматов подписки (URI-строки,
/// Xray-JSON, INI/Amnezia), поэтому одно правило работает везде.
///
/// Порядок: правила применяются сверху вниз. REPLACE меняет JSON узла, и
/// следующее правило видит уже изменённый вид — это позволяет строить цепочки.
/// DISABLE помечает узел; на дальнейшее вычисление правил это не влияет
/// (пометка — решение о роутинге, а не о структуре).

/// Что правила сделали с одним узлом.
class NodeRuleOutcome {
  /// Узел помечен к выключению (`Disable`).
  final bool disabled;

  /// JSON узла после всех REPLACE. `null` — изменений не было.
  final Map<String, dynamic>? patchedJson;

  /// Человекочитаемые следы замен для UI: «tls.utls.fingerprint:
  /// hellochrome_120 → chrome».
  final List<String> replacements;

  const NodeRuleOutcome({
    this.disabled = false,
    this.patchedJson,
    this.replacements = const [],
  });

  bool get changed => disabled || patchedJson != null;
}

/// Результат применения набора правил ко всем узлам подписки.
class ImportRulesResult {
  /// Индексы узлов (в исходном списке), помеченных к выключению.
  final Set<int> disabledIndexes;

  /// Итог по каждому узлу — по индексу исходного списка. Узлы, которых
  /// правила не коснулись, в карте отсутствуют.
  final Map<int, NodeRuleOutcome> outcomes;

  const ImportRulesResult({
    this.disabledIndexes = const {},
    this.outcomes = const {},
  });

  bool get isEmpty => disabledIndexes.isEmpty && outcomes.isEmpty;
}

/// Прогоняет [rules] по [nodes]. Pure: узлы не мутируются, ничего не пишет.
///
/// Вызывающий (контроллер) решает, что делать с результатом: выключить узлы
/// через §283 `disabledHashes` и/или применить `patchedJson`.
ImportRulesResult applyImportRules(List<NodeSpec> nodes, List<ImportRule> rules,
    {TemplateVars vars = TemplateVars.empty}) {
  final usable = rules.where((r) => r.isUsable).toList();
  if (usable.isEmpty || nodes.isEmpty) return const ImportRulesResult();

  final disabled = <int>{};
  final outcomes = <int, NodeRuleOutcome>{};

  for (var i = 0; i < nodes.length; i++) {
    final outcome = applyRulesToNode(nodes[i], usable, vars: vars);
    if (!outcome.changed) continue;
    outcomes[i] = outcome;
    if (outcome.disabled) disabled.add(i);
  }

  return ImportRulesResult(disabledIndexes: disabled, outcomes: outcomes);
}

/// Применяет правила к одному узлу. Вынесено отдельно — этим же путём ходит
/// предпросмотр в редакторе правила (тот же результат, что при импорте).
NodeRuleOutcome applyRulesToNode(NodeSpec node, List<ImportRule> rules,
    {TemplateVars vars = TemplateVars.empty}) {
  // Рабочая копия JSON узла: REPLACE правит её, следующее правило видит
  // изменённый вид. §307 — основа СТРОГО `emitRaw` (канонический вид узла),
  // а не `emit`: тот отдаёт прошлый патч, и правила читали бы собственный
  // предыдущий результат как исходник — повторное применение накапливалось
  // бы. Прогон всех правил с нуля на каждом применении = детерминизм.
  final json = node.emitRaw(vars).map;
  var patched = false;
  var disabled = false;
  final trail = <String>[];

  for (final rule in rules) {
    final match = _evaluate(rule, json);
    if (!match.matched) continue;

    if (rule.action == ImportRuleAction.disable) {
      disabled = true;
      continue;
    }

    // §307 — пустая цель = substitute по ВСЕМУ узлу (симметрия с пустым
    // путём условия «ищи везде»): найти паттерн в любом листе JSON и
    // заменить только найденный фрагмент.
    if (rule.targetPath.isEmpty) {
      final changes = _substituteWholeNode(json, rule);
      if (changes.isNotEmpty) {
        patched = true;
        trail.addAll(changes);
      }
      continue;
    }

    final before = readJsonPath(json, rule.targetPath);
    final next = _buildReplacement(rule, match, before);
    if (next == null || next == before) continue;
    if (!writeJsonPath(json, rule.targetPath, next)) continue;
    patched = true;
    trail.add('${rule.targetPath}: ${before ?? '(none)'} → $next');
  }

  return NodeRuleOutcome(
    disabled: disabled,
    patchedJson: patched ? json : null,
    replacements: trail,
  );
}

/// Итог вычисления условий правила.
class _MatchResult {
  final bool matched;

  /// Карманы (`$1`…`$9`) по путям: группы захвата `matches`-условий.
  /// Ключ — путь условия, значение — список групп (индекс 0 = `$1`).
  final Map<JsonPath, List<String>> groups;

  const _MatchResult(this.matched, [this.groups = const {}]);
}

_MatchResult _evaluate(ImportRule rule, Map<String, dynamic> json) {
  final conds = rule.usableConditions;
  if (conds.isEmpty) return const _MatchResult(false);

  final groups = <JsonPath, List<String>>{};
  var anyTrue = false;
  var allTrue = true;

  for (final c in conds) {
    final value = readJsonPath(json, c.path);
    final hit = _test(c, value, groups);
    if (hit) {
      anyTrue = true;
    } else {
      allTrue = false;
    }
  }

  final matched =
      rule.matchMode == ImportRuleMatchMode.all ? allTrue : anyTrue;
  return _MatchResult(matched, groups);
}

/// Проверяет одно условие. Побочно копит карманы для `matches`.
bool _test(ImportRuleCondition c, String? value,
    Map<JsonPath, List<String>> groups) {
  // Пути нет — условие ложно; с `negate` это делает его истинным, что и
  // даёт «поля нет / поле не такое».
  if (value == null) return c.negate;

  var hit = false;
  switch (c.op) {
    case ImportRuleOperator.contains:
      hit = c.caseSensitive
          ? value.contains(c.pattern)
          : value.toLowerCase().contains(c.pattern.toLowerCase());
    case ImportRuleOperator.equals:
      hit = c.caseSensitive
          ? value == c.pattern
          : value.toLowerCase() == c.pattern.toLowerCase();
    case ImportRuleOperator.matches:
      final re = c.compiledPattern;
      if (re == null) return c.negate;
      final m = re.firstMatch(value);
      hit = m != null;
      if (m != null) {
        groups[c.path] = [
          for (var g = 1; g <= m.groupCount; g++) m.group(g) ?? '',
        ];
      }
  }
  return c.negate ? !hit : hit;
}

/// Собирает новое значение для Replace.
String? _buildReplacement(
    ImportRule rule, _MatchResult match, String? currentValue) {
  final pockets = match.groups[rule.targetPath] ??
      // Карманы берём по цели; если по ней условия не было — по первому
      // matches-условию правила (частый случай: условие и цель — один путь,
      // но пользователь мог указать разные).
      (match.groups.isEmpty ? const <String>[] : match.groups.values.first);

  final expanded = _expandPockets(rule.replacement, pockets);

  switch (rule.replaceMode) {
    case ImportRuleReplaceMode.set:
      return expanded;

    case ImportRuleReplaceMode.substitute:
      if (currentValue == null) return null;
      // Что искать внутри значения: явный substitutePattern, иначе паттерн
      // условия по тому же пути.
      final needle = rule.substitutePattern.isNotEmpty
          ? rule.substitutePattern
          : _patternForPath(rule, rule.targetPath);
      if (needle == null || needle.isEmpty) return null;

      final cond = _conditionForPath(rule, rule.targetPath);
      final useRegex = rule.substitutePattern.isEmpty &&
          cond?.op == ImportRuleOperator.matches;
      final caseSensitive = cond?.caseSensitive ?? false;
      try {
        final re = useRegex
            ? RegExp(needle, caseSensitive: caseSensitive)
            : RegExp(RegExp.escape(needle), caseSensitive: caseSensitive);
        return currentValue.replaceAllMapped(
          re,
          (m) => _expandPockets(
            rule.replacement,
            [for (var g = 1; g <= m.groupCount; g++) m.group(g) ?? ''],
          ),
        );
      } catch (_) {
        return null;
      }
  }
}

/// §307 — substitute по всему узлу (пустой `targetPath`): обходит все листья
/// JSON, в каждом ищет паттерн и заменяет найденные фрагменты. Что искать —
/// как в обычном substitute: явный `substitutePattern`, иначе паттерн условия
/// с пустым путём (regex, если это `matches`-условие — тогда карманы `$1`…
/// берутся из совпадения в самом листе). Типы значений сохраняются (порт
/// остаётся числом). Возвращает следы замен («путь: до → после»).
///
/// Режим `set` с пустой целью смысла не имеет (весь узел строкой не
/// затирается) — такое правило непригодно уже в [ImportRule.isUsable].
List<String> _substituteWholeNode(Map<String, dynamic> json, ImportRule rule) {
  if (rule.replaceMode != ImportRuleReplaceMode.substitute) return const [];

  final needle = rule.substitutePattern.isNotEmpty
      ? rule.substitutePattern
      : _patternForPath(rule, '');
  if (needle == null || needle.isEmpty) return const [];

  final cond = _conditionForPath(rule, '');
  final useRegex = rule.substitutePattern.isEmpty &&
      cond?.op == ImportRuleOperator.matches;
  final caseSensitive = cond?.caseSensitive ?? false;
  final RegExp re;
  try {
    re = useRegex
        ? RegExp(needle, caseSensitive: caseSensitive)
        : RegExp(RegExp.escape(needle), caseSensitive: caseSensitive);
  } catch (_) {
    return const [];
  }

  final trail = <String>[];

  // Замена в одном листе; null = не изменился. Не-строки сравниваем через
  // toString (как readJsonPath), тип восстанавливает _coerceLike.
  Object? replaceLeaf(Object value) {
    final before = value.toString();
    final after = before.replaceAllMapped(
      re,
      (m) => _expandPockets(
        rule.replacement,
        [for (var g = 1; g <= m.groupCount; g++) m.group(g) ?? ''],
      ),
    );
    return after == before ? null : coerceJsonLike(value, after);
  }

  void visit(Object? node, String prefix,
      void Function(Object coerced) write) {
    if (node is Map<String, dynamic>) {
      // Снимок ключей — замена пишет в тот же контейнер.
      for (final key in node.keys.toList()) {
        final path = prefix.isEmpty ? key : '$prefix.$key';
        visit(node[key], path, (v) => node[key] = v);
      }
      return;
    }
    if (node is List) {
      for (var i = 0; i < node.length; i++) {
        visit(node[i], '$prefix.$i', (v) => node[i] = v);
      }
      return;
    }
    if (node == null) return;
    final next = replaceLeaf(node);
    if (next == null) return;
    write(next);
    trail.add('$prefix: $node → $next');
  }

  visit(json, '', (_) {});
  return trail;
}

ImportRuleCondition? _conditionForPath(ImportRule rule, JsonPath path) {
  for (final c in rule.usableConditions) {
    if (c.path == path) return c;
  }
  return null;
}

String? _patternForPath(ImportRule rule, JsonPath path) =>
    _conditionForPath(rule, path)?.pattern;

/// Подставляет карманы `$1`…`$9`. `$$` — литеральный доллар.
String _expandPockets(String template, List<String> pockets) {
  if (!template.contains(r'$')) return template;
  final out = StringBuffer();
  for (var i = 0; i < template.length; i++) {
    final ch = template[i];
    if (ch != r'$' || i + 1 >= template.length) {
      out.write(ch);
      continue;
    }
    final next = template[i + 1];
    if (next == r'$') {
      out.write(r'$');
      i++;
      continue;
    }
    final idx = int.tryParse(next);
    if (idx == null || idx < 1) {
      out.write(ch);
      continue;
    }
    out.write(idx <= pockets.length ? pockets[idx - 1] : '');
    i++;
  }
  return out.toString();
}
