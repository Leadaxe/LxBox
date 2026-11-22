/// §757 — тело собственного правила маршрута как дерево условий
/// (контракт 1.1.179, TASKS_LXBOX §182 п. 1.1–1.2, BACKUP.md таблица
/// `rules[]`).
///
/// Тело — простое правило ([RuleLeaf]) либо `logical` ([RuleGroup]) с
/// вложенными простыми и составными правилами. Ссылки на наборы (`refs`)
/// живут внутри простого правила на любом уровне; цель (`outbound` |
/// `action` + `method`) — только у корня ([RuleTreeBody.target]).
///
/// Какие ключи — условия, берётся из таблицы условий реестра
/// ([RuleConditionTable]); имён ключей условий здесь нет.
///
/// Подключено к `CustomRuleTree`, кодеку записи и сборке (волна B §757).
library;

import '../services/contract/rule_conditions.dart';

/// §757 — узел дерева тела правила.
sealed class RuleNode {
  const RuleNode({this.invert = false});

  /// `not` узла. В набор не уходит никогда — остаётся на узле (§6.13 п. 2).
  final bool invert;
}

/// §757 — простое правило (лист дерева).
final class RuleLeaf extends RuleNode {
  const RuleLeaf({
    this.conditions = const {},
    this.refs = const [],
    this.ruleSet = const [],
    super.invert,
  });

  /// Ключи условий таблицы (кроме `refs`) → значение в форме sing-box:
  /// список строк, список чисел (порты) или `true` (флаг). Пустые списки и
  /// `false` при разборе не хранятся — у ядра они не условие.
  final Map<String, Object> conditions;

  /// Ссылки на наборы (URL или путь) в порядке записи; ссылка не меняется.
  final List<String> refs;

  /// Рукописные теги `rule_set` тела — при выпуске стоят первыми (§6.13 п. 3).
  final List<String> ruleSet;

  RuleLeaf copyWith({
    Map<String, Object>? conditions,
    List<String>? refs,
    List<String>? ruleSet,
    bool? invert,
  }) => RuleLeaf(
    conditions: conditions ?? this.conditions,
    refs: refs ?? this.refs,
    ruleSet: ruleSet ?? this.ruleSet,
    invert: invert ?? this.invert,
  );
}

/// §757 — `logical`-узел: `and` | `or` над детьми.
final class RuleGroup extends RuleNode {
  const RuleGroup({required this.mode, required this.children, super.invert});

  /// `and` | `or`.
  final String mode;
  final List<RuleNode> children;

  static const kAnd = 'and';
  static const kOr = 'or';
  static const kLogical = 'logical';
}

/// §757 — разобранное тело записи: дерево условий и цель корня.
final class RuleTreeBody {
  const RuleTreeBody({required this.root, this.target = const {}});

  final RuleNode root;

  /// Ключи цели корня (`outbound` | `action`, `method`) как в теле.
  final Map<String, dynamic> target;
}

/// §757 — ключ ссылок в теле и на записи старой формы (BACKUP.md).
const kRuleRefsKey = 'refs';

/// §757 — одиночная ссылка записи старой формы (до ## 12 контракта).
const kRuleRefKey = 'ref';

/// §757 — ссылки старой формы на ЗАПИСИ `rules[]` (`refs`, либо одиночный
/// `ref` как `refs[0]`). У записи-пресета `ref` — id пресета, не ссылка:
/// для неё пусто.
List<String> legacyRecordRefs(Map<dynamic, dynamic> record) {
  if (record['kind'] == 'preset') return const [];
  final refs = _readStringList(record[kRuleRefsKey]);
  if (refs != null && refs.isNotEmpty) return refs;
  final single = record[kRuleRefKey];
  if (single is String && single.trim().isNotEmpty) return [single];
  return const [];
}

/// §757 — разбор тела записи в дерево.
///
/// `null` — тело не дерево, вызывающий оставляет правило JSON-видом:
/// ключ вне таблицы условий и вне служебных; `refs` у `logical`; цель не у
/// корня; значение не той формы (не список строк / чисел, не флаг);
/// `logical` без `mode` `and`|`or` или без детей.
///
/// [recordRefs] — ссылки старой формы с записи ([legacyRecordRefs]); они
/// переносятся в корень по TASKS_LXBOX §182 п. 1.2: корень простой —
/// `refs` в него; корень `logical` — обёртка `and` из `{refs}` и тела без
/// цели. Есть `refs` и в дереве — главнее дерево, [recordRefs] игнорируется.
RuleTreeBody? parseRuleTreeBody(
  Map<String, dynamic> body,
  RuleConditionTable table, {
  List<String> recordRefs = const [],
}) {
  final target = <String, dynamic>{};
  for (final k in RuleConditionTable.targetKeys) {
    if (body.containsKey(k)) target[k] = body[k];
  }
  final root = _parseNode(body, table, isRoot: true);
  if (root == null) return null;
  final legacy = [
    for (final r in recordRefs)
      if (r.trim().isNotEmpty) r,
  ];
  if (legacy.isEmpty || ruleTreeRefs(root).isNotEmpty) {
    return RuleTreeBody(root: root, target: target);
  }
  final moved = switch (root) {
    RuleLeaf() => root.copyWith(refs: legacy),
    RuleGroup() => RuleGroup(
      mode: RuleGroup.kAnd,
      children: [
        RuleLeaf(refs: legacy),
        root,
      ],
    ),
  };
  return RuleTreeBody(root: moved, target: target);
}

RuleNode? _parseNode(
  Map<String, dynamic> m,
  RuleConditionTable table, {
  required bool isRoot,
}) {
  final type = m[RuleConditionTable.kType];
  final invertRaw = m[RuleConditionTable.kInvert];
  if (invertRaw != null && invertRaw is! bool) return null;
  final invert = invertRaw == true;

  if (type == RuleGroup.kLogical) {
    final mode = m[RuleConditionTable.kMode];
    if (mode != RuleGroup.kAnd && mode != RuleGroup.kOr) return null;
    final rules = m[RuleConditionTable.kRules];
    if (rules is! List || rules.isEmpty) return null;
    for (final k in m.keys) {
      if (k == RuleConditionTable.kType ||
          k == RuleConditionTable.kMode ||
          k == RuleConditionTable.kRules ||
          k == RuleConditionTable.kInvert) {
        continue;
      }
      if (isRoot && RuleConditionTable.targetKeys.contains(k)) continue;
      // `refs`, `rule_set` и условия у `logical` — не дерево.
      return null;
    }
    final children = <RuleNode>[];
    for (final c in rules) {
      if (c is! Map) return null;
      final child = _parseNode(
        Map<String, dynamic>.from(c),
        table,
        isRoot: false,
      );
      if (child == null) return null;
      children.add(child);
    }
    return RuleGroup(
      mode: mode as String,
      children: List.unmodifiable(children),
      invert: invert,
    );
  }
  // Простое правило: `type` нет или `default` (так его пишет ядро).
  if (type != null && type != 'default') return null;

  final conditions = <String, Object>{};
  var refs = const <String>[];
  var ruleSet = const <String>[];
  for (final e in m.entries) {
    final k = e.key;
    if (k == RuleConditionTable.kType || k == RuleConditionTable.kInvert) {
      continue;
    }
    if (RuleConditionTable.targetKeys.contains(k)) {
      if (isRoot) continue;
      return null; // цель — только у корня
    }
    if (k == RuleConditionTable.kRuleSet) {
      final tags = _readStringList(e.value);
      if (tags == null) return null;
      ruleSet = List.unmodifiable(tags.where((t) => t.isNotEmpty));
      continue;
    }
    if (RuleConditionTable.serviceKeys.contains(k)) {
      return null; // `mode` / `rules` у простого правила
    }
    final desc = table.key(k);
    if (desc == null) return null; // ключ вне таблицы — JSON-вид
    if (desc.isRefs) {
      final list = _readStringList(e.value);
      if (list == null) return null;
      refs = List.unmodifiable(list.where((r) => r.trim().isNotEmpty));
      continue;
    }
    final v = _readValue(desc, e.value);
    if (v == _invalid) return null;
    if (v != null) conditions[k] = v;
  }
  return RuleLeaf(
    conditions: Map.unmodifiable(conditions),
    refs: refs,
    ruleSet: ruleSet,
    invert: invert,
  );
}

const Object _invalid = Object();

/// Значение условия в форме хранения; `null` — пусто (ключ не хранится),
/// [_invalid] — форма не та.
Object? _readValue(RuleConditionKey desc, Object? raw) {
  if (desc.isBool) {
    if (raw is! bool) return _invalid;
    return raw ? true : null;
  }
  if (desc.isIntList) {
    final items = raw is List ? raw : [raw];
    final out = <int>[];
    for (final i in items) {
      if (i is int) {
        out.add(i);
      } else if (i is num && i == i.roundToDouble()) {
        out.add(i.toInt());
      } else {
        return _invalid;
      }
    }
    return out.isEmpty ? null : List<int>.unmodifiable(out);
  }
  final list = _readStringList(raw);
  if (list == null) return _invalid;
  return list.isEmpty ? null : List<String>.unmodifiable(list);
}

/// Скаляр вместо списка читается списком (ядро принимает оба).
List<String>? _readStringList(Object? raw) {
  if (raw == null) return const [];
  if (raw is String) return [raw];
  if (raw is! List) return null;
  final out = <String>[];
  for (final e in raw) {
    if (e is! String) return null;
    out.add(e);
  }
  return out;
}

/// §757 — тело в новой форме (`refs` внутри простого правила, цель на
/// корне). Рукописный `rule_set` — списком.
Map<String, dynamic> ruleTreeBodyToJson(RuleTreeBody body) => {
  ..._nodeToJson(body.root),
  ...body.target,
};

Map<String, dynamic> _nodeToJson(RuleNode n) => switch (n) {
  RuleLeaf() => {
    if (n.refs.isNotEmpty) kRuleRefsKey: List<String>.of(n.refs),
    // §757 — списком всегда (корпус `backup/v11_rule_refs_in_body`, «Hand
    // set»): тело записи хранит теги в форме списка.
    if (n.ruleSet.isNotEmpty) RuleConditionTable.kRuleSet: List.of(n.ruleSet),
    for (final e in n.conditions.entries)
      e.key: e.value is List ? List.of(e.value as List) : e.value,
    if (n.invert) RuleConditionTable.kInvert: true,
  },
  RuleGroup() => {
    RuleConditionTable.kType: RuleGroup.kLogical,
    RuleConditionTable.kMode: n.mode,
    RuleConditionTable.kRules: [for (final c in n.children) _nodeToJson(c)],
    if (n.invert) RuleConditionTable.kInvert: true,
  },
};

/// §757 — обход простых узлов pre-order с путём (индексы `rules[]` от корня;
/// у корня путь пустой).
Iterable<(List<int>, RuleLeaf)> ruleTreeLeaves(RuleNode root) sync* {
  Iterable<(List<int>, RuleLeaf)> walk(RuleNode n, List<int> path) sync* {
    switch (n) {
      case RuleLeaf():
        yield (path, n);
      case RuleGroup():
        for (var i = 0; i < n.children.length; i++) {
          yield* walk(n.children[i], [...path, i]);
        }
    }
  }

  yield* walk(root, const []);
}

/// §757 — путь узла строкой (`0`, `1.0`); у корня — пусто.
String ruleTreePath(List<int> path) => path.join('.');

/// §757 — все ссылки дерева pre-order без повторов (повтор — по ссылке с
/// обрезанными краями: одна ссылка — один набор, §6.13 п. 4).
List<String> ruleTreeRefs(RuleNode root) {
  final seen = <String>{};
  return [
    for (final (_, leaf) in ruleTreeLeaves(root))
      for (final r in leaf.refs)
        if (seen.add(r.trim())) r,
  ];
}

/// §757 — `kind` записи выводится из дерева (TASKS_LXBOX §182 п. 1.2).
String ruleTreeKind(RuleNode root) =>
    ruleTreeRefs(root).isEmpty ? 'inline' : 'srs';

/// §757 — хоть в одном простом узле есть `refs` или доменный ключ (группа
/// `domain` таблицы) с ненулевым значением: условие Block HTTPS (§6.11) и
/// resolve-способности правила (§247).
bool ruleTreeHasRefsOrDomain(RuleNode root, RuleConditionTable table) {
  for (final (_, leaf) in ruleTreeLeaves(root)) {
    if (leaf.refs.isNotEmpty) return true;
    for (final k in leaf.conditions.keys) {
      if (table.key(k)?.isDomain ?? false) return true;
    }
  }
  return false;
}
