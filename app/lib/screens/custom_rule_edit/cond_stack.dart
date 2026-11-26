/// §757 волна 4 — модель формы правила: дерево условий ([RuleNode]) ⇄
/// стопка условий-рамок и групп правил (по образцу формы лаунчера,
/// SPEC 188 §6, `ui/configurator/models/rule_conditions.go`).
///
/// Что за условие у ключа, вид поля и порядок условий — таблица условий
/// реестра ([RuleConditionTable], условия с `forms` ∋ `lxbox`); имён
/// условий и ключей здесь нет.
///
/// Хранение: простое правило — условия стопки; правило с группами —
/// `logical and`, первым под-правилом условия стопки, следом каждая группа;
/// одна группа без других условий — сама группа. `invert` простого правила
/// форма показывает группой «all of» с «Not» вокруг него. Значения полей
/// хранятся сырыми (текст поля, выбор чипов, флажок) и приводятся к значению
/// ключа при сборке узла ([CondStack.toNode]).
///
/// Чистый Dart, без Flutter: модель меняет контроллер формы, рамки рисуют
/// виджеты секции условий.
library;

import '../../models/custom_rule.dart' show parseSrsUrlsText;
import '../../models/rule_tree.dart';
import '../../services/contract/rule_conditions.dart';
import 'normalizers.dart' as norm;

/// §757 — форма LxBox в поле `forms` таблицы условий.
const kRuleCondFormLxbox = 'lxbox';

/// §757 — у ключа поле — чипы закрытого выбора (`enum_multi` без `open`):
/// сырое значение — список выбранных. Открытый выбор — текст по строке с
/// подсказками.
bool condKeyIsChips(RuleConditionKey k) =>
    k.field == kCondFieldEnumMulti && !k.open;

const kCondFieldEnumMulti = 'enum_multi';
const kCondFieldCidrLines = 'cidr_lines';

/// §757 — заполненное условие-рамка. [raw]: ключ → текст поля (`String`),
/// выбор чипов (`List<String>`) или флажок (`bool`).
final class CondFrame {
  CondFrame(this.cond, [Map<String, Object>? raw]) : raw = raw ?? {};

  final RuleCondition cond;
  final Map<String, Object> raw;

  /// Текст поля ключа (пусто — нет).
  String text(String key) {
    final v = raw[key];
    return v is String ? v : '';
  }

  /// Выбор чипов ключа.
  List<String> chips(String key) {
    final v = raw[key];
    return v is List<String> ? v : const [];
  }

  bool flag(String key) => raw[key] == true;
}

/// §757 — группа правил: «all of» (`and`) | «any of» (`or`), «Not».
final class CondGroup {
  CondGroup({this.any = false, this.not = false, List<CondStack>? rules})
      : rules = rules ?? [];

  bool any;
  bool not;
  final List<CondStack> rules;
}

/// §757 — простое правило формы: условия (между собой «и») и группы правил
/// (тоже «и» с условиями).
final class CondStack {
  CondStack({
    List<CondFrame>? frames,
    List<CondGroup>? groups,
    Map<String, Object>? hidden,
    this.ruleSet = const [],
  })  : frames = frames ?? [],
        groups = groups ?? [],
        hidden = hidden ?? {};

  final List<CondFrame> frames;
  final List<CondGroup> groups;

  /// Ключи условий, которых форма LxBox не показывает: провозятся как есть.
  final Map<String, Object> hidden;

  /// Рукописные теги `rule_set` простого правила: провозятся как есть.
  final List<String> ruleSet;

  bool get isEmpty =>
      frames.isEmpty && groups.isEmpty && hidden.isEmpty && ruleSet.isEmpty;

  /// Рамка условия [id] в стопке; null — условие не добавлено.
  CondFrame? frame(String id) {
    for (final f in frames) {
      if (f.cond.id == id) return f;
    }
    return null;
  }

  /// §757 — стопка из узла дерева. null — узел форма не выражает (два ключа
  /// условия `one_of` сразу): правило правится в JSON.
  static CondStack? fromNode(RuleNode node, RuleConditionTable table) {
    return switch (node) {
      RuleLeaf() => _fromLeafForForm(node, table),
      RuleGroup() => _fromGroupRoot(node, table),
    };
  }

  static CondStack? _fromLeafForForm(RuleLeaf leaf, RuleConditionTable t) {
    final s = _fromLeaf(leaf, t);
    if (s == null || !leaf.invert) return s;
    // `invert` простого правила — группа «all of» с «Not» вокруг него.
    return CondStack(groups: [
      CondGroup(not: true, rules: [s]),
    ]);
  }

  static CondStack? _fromGroupRoot(RuleGroup g, RuleConditionTable t) {
    final c = g.children;
    if (g.mode == RuleGroup.kAnd && !g.invert && c.length >= 2) {
      final restAreGroups = c.skip(1).every((n) => n is RuleGroup);
      final first = c.first;
      if (restAreGroups && first is RuleLeaf && !first.invert) {
        final s = _fromLeaf(first, t);
        if (s == null) return null;
        if (!s.isEmpty) {
          for (final n in c.skip(1)) {
            final grp = _groupFrom(n as RuleGroup, t);
            if (grp == null) return null;
            s.groups.add(grp);
          }
          return s;
        }
      } else if (c.every((n) => n is RuleGroup)) {
        final s = CondStack();
        for (final n in c) {
          final grp = _groupFrom(n as RuleGroup, t);
          if (grp == null) return null;
          s.groups.add(grp);
        }
        return s;
      }
    }
    final grp = _groupFrom(g, t);
    if (grp == null) return null;
    return CondStack(groups: [grp]);
  }

  static CondGroup? _groupFrom(RuleGroup g, RuleConditionTable t) {
    final out = CondGroup(any: g.mode == RuleGroup.kOr, not: g.invert);
    for (final n in g.children) {
      final s = fromNode(n, t);
      if (s == null) return null;
      out.rules.add(s);
    }
    return out;
  }

  static CondStack? _fromLeaf(RuleLeaf leaf, RuleConditionTable t) {
    final s = CondStack(ruleSet: List.of(leaf.ruleSet));
    final byCond = <String, Map<String, Object>>{};
    void put(RuleConditionKey d, Object value) {
      final cond = t.condition(d.conditionId);
      if (cond == null || !cond.shownIn(kRuleCondFormLxbox)) {
        s.hidden[d.key] = value;
        return;
      }
      (byCond[cond.id] ??= {})[d.key] = _rawFromValue(d, value);
    }

    if (leaf.refs.isNotEmpty) {
      final d = t.key(t.refsKey);
      if (d != null) put(d, leaf.refs);
    }
    for (final e in leaf.conditions.entries) {
      final d = t.key(e.key);
      if (d == null) {
        s.hidden[e.key] = e.value;
        continue;
      }
      put(d, e.value);
    }
    for (final cond in t.conditions) {
      final raw = byCond[cond.id];
      if (raw == null) continue;
      // Два способа условия `one_of` сразу ядро связывает «и» — форма
      // выбирает один; такое тело правится в JSON.
      if (cond.oneOf && raw.length > 1) return null;
      s.frames.add(CondFrame(cond, raw));
    }
    return s;
  }

  static Object _rawFromValue(RuleConditionKey d, Object value) {
    if (d.isBool) return value == true;
    final list = value is List ? [for (final e in value) e.toString()] : [];
    if (condKeyIsChips(d)) return List<String>.of(list.cast<String>());
    return list.join('\n');
  }

  /// §757 — узел дерева из стопки; null — писать нечего. Пустые поля и
  /// условия не пишутся, пустые правила и группы выбрасываются.
  RuleNode? toNode() {
    final leaf = _leaf();
    final gs = [
      for (final g in groups) ?g.toNode(),
    ];
    if (gs.isEmpty) return leaf;
    if (leaf == null && gs.length == 1) return gs.single;
    return RuleGroup(
      mode: RuleGroup.kAnd,
      children: List.unmodifiable([?leaf, ...gs]),
    );
  }

  RuleLeaf? _leaf() {
    final conditions = <String, Object>{};
    var refs = const <String>[];
    for (final f in frames) {
      for (final k in f.cond.keys) {
        final raw = f.raw[k.key];
        if (raw == null) continue;
        if (k.isRefs) {
          refs = List.unmodifiable(parseSrsUrlsText(raw as String));
          continue;
        }
        final v = condValue(k, raw);
        if (v != null) conditions[k.key] = v;
      }
    }
    for (final e in hidden.entries) {
      conditions.putIfAbsent(e.key, () => e.value);
    }
    if (conditions.isEmpty && refs.isEmpty && ruleSet.isEmpty) return null;
    return RuleLeaf(
      conditions: Map.unmodifiable(conditions),
      refs: refs,
      ruleSet: List.unmodifiable(ruleSet),
    );
  }

  /// Все рамки стопки и под-правил её групп (рекурсивно).
  Iterable<CondFrame> get allFrames sync* {
    yield* frames;
    for (final g in groups) {
      for (final r in g.rules) {
        yield* r.allFrames;
      }
    }
  }
}

extension CondGroupNode on CondGroup {
  RuleNode? toNode() {
    final children = [
      for (final r in rules) ?r.toNode(),
    ];
    if (children.isEmpty) return null;
    // «all of» с «Not» вокруг одного простого правила — это `invert` самого
    // правила (так его и пишет ядро; круг «тело → форма → тело» точный).
    final only = children.length == 1 ? children.single : null;
    if (not && !any && only is RuleLeaf && !only.invert) {
      return only.copyWith(invert: true);
    }
    return RuleGroup(
      mode: any ? RuleGroup.kOr : RuleGroup.kAnd,
      children: List.unmodifiable(children),
      invert: not,
    );
  }
}

/// §757 — сырое значение поля → значение ключа узла; null — пусто (ключ не
/// пишется).
Object? condValue(RuleConditionKey k, Object raw) {
  if (k.isBool) return raw == true ? true : null;
  if (raw is List) {
    return raw.isEmpty ? null : List<String>.unmodifiable(raw.cast<String>());
  }
  final text = raw as String;
  if (k.isIntList) {
    final ports = <int>[
      for (final p in norm.splitRaw(text))
        if (int.tryParse(p) case final n? when n >= 0 && n <= 65535) n,
    ];
    return ports.isEmpty ? null : List<int>.unmodifiable(ports);
  }
  final List<String> lines = switch (k.field) {
    kCondFieldCidrLines => norm.normalizedCidrs(text),
    _ => norm.normalizedConditionLines(k.key, text),
  };
  return lines.isEmpty ? null : List<String>.unmodifiable(lines);
}

/// §757 — рамка пуста: ни одно поле не даёт значения ключа.
bool condFrameEmpty(CondFrame f) {
  for (final k in f.cond.keys) {
    final raw = f.raw[k.key];
    if (raw == null) continue;
    if (k.isRefs) {
      if (parseSrsUrlsText(raw as String).isNotEmpty) return false;
      continue;
    }
    if (condValue(k, raw) != null) return false;
  }
  return true;
}
