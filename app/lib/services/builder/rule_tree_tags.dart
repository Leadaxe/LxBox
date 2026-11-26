/// §757 — теги наборов собственных правил (TEMPLATE_LANG §6.13 «Теги
/// наборов», контракт 1.1.179–1.1.182, D-157, D-158): одна схема у LxBox и лаунчера.
///
/// Чистая функция над осью правил: базы раздаются всем записям `inline` |
/// `srs` (включая verbatim и выключенные) до производных, производные — в
/// порядке оси, внутри правила pre-order (ссылки узла по порядку `refs`,
/// затем его inline-набор).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/rule_tree.dart';
import '../contract/rule_conditions.dart';

/// §757 — запись оси для раздачи тегов.
final class RuleTagInput {
  const RuleTagInput({required this.name, this.root});

  /// Имя правила как есть (база считается в [ruleTagBase], §757).
  final String name;

  /// Дерево тела; null — запись без дерева (verbatim-JSON): берёт только
  /// базу.
  final RuleNode? root;
}

/// §757 — теги одной записи.
final class RuleTags {
  const RuleTags({
    required this.base,
    this.refTags = const {},
    this.inlineTags = const {},
  });

  /// `B'` — база правила после развода (§6.13 п. 3).
  final String base;

  /// Ссылка (края обрезаны) → тег набора.
  final Map<String, String> refTags;

  /// Путь узла ([ruleTreePath]; у корня — пусто) → тег inline-набора узла.
  final Map<String, String> inlineTags;

  /// Тег ссылки [ref] (поиск по обрезанной строке).
  String? tagOfRef(String ref) => refTags[ref.trim()];
}

/// §757 — база `B`: имя правила с обрезанными краями, пустое после обрезки
/// — `unnamed` (§6.13, контракт 1.1.180). Обрезка здесь, а не у вызывающего.
String ruleTagBase(String name) {
  final t = name.trim();
  return t.isEmpty ? 'unnamed' : t;
}

/// §757 — h8: первые 8 hex sha256 строки ссылки (UTF-8, края обрезаны,
/// нижний регистр); [length] 16 — при совпадении h8 внутри правила.
String ruleRefHash(String ref, {int length = 8}) =>
    sha256.convert(utf8.encode(ref.trim())).toString().substring(0, length);

/// §757 — stem ссылки (§6.13 п. 4, TASKS_LXBOX §185 п. 1): последний
/// сегмент пути (query и fragment отброшены), percent-encoding снят ПОСЛЕ
/// разбиения на сегменты (`a%2Fb.srs` → `a/b`), снято только последнее
/// расширение `.srs` / `.json` без учёта регистра; регистр сохраняется.
/// Пустая строка — пустой stem (тег `B':<h8>`).
String ruleRefStem(String ref) {
  final r = ref.trim();
  String segment;
  final uri = Uri.tryParse(r);
  if (uri != null) {
    // `Uri.path` — в закодированном виде: `%2F` ещё не стал разделителем.
    segment = uri.path.split('/').last;
  } else {
    // Не разбирается как URL — режем вручную: `#`, затем `?`, затем `/`.
    var s = r;
    final hash = s.indexOf('#');
    if (hash >= 0) s = s.substring(0, hash);
    final q = s.indexOf('?');
    if (q >= 0) s = s.substring(0, q);
    final schemeEnd = s.indexOf('://');
    if (schemeEnd >= 0) {
      final rest = s.substring(schemeEnd + 3);
      final slash = rest.indexOf('/');
      s = slash < 0 ? '' : rest.substring(slash);
    }
    segment = s.split('/').last;
  }
  try {
    segment = Uri.decodeComponent(segment);
  } on Object {
    // Битая percent-последовательность — сегмент как есть.
  }
  final lower = segment.toLowerCase();
  for (final ext in const ['.srs', '.json']) {
    if (lower.endsWith(ext)) {
      return segment.substring(0, segment.length - ext.length);
    }
  }
  return segment;
}

/// §757 — у узла будет inline-набор: есть ключ `set: true` с ненулевым
/// значением и (у узла есть `refs` или сторона уводит ключи узла без
/// `refs` в набор — [sideInlineSets], §6.13 п. 4).
bool ruleLeafHasInlineSet(
  RuleLeaf leaf,
  RuleConditionTable table, {
  required bool sideInlineSets,
}) {
  if (leaf.refs.isEmpty && !sideInlineSets) return false;
  return leaf.conditions.keys.any((k) => table.key(k)?.set ?? false);
}

/// §757 — раздача тегов всем записям оси (§6.13 п. 1–5).
///
/// [reserved] — заняты заранее: теги `route.rule_set` шаблона и теги наборов
/// всех пресетов, стоящих в `rules[]` (включённых и нет). [sideInlineSets] —
/// выбор стороны §6.13 п. 4 (LxBox — включён): от него зависит, у каких
/// узлов без `refs` есть inline-набор, а значит и какие производные теги
/// выданы.
///
/// Производные теги раздаются и выключенным записям с деревом: тег зависит
/// только от имён и порядка (§6.13 п. 2).
List<RuleTags> assignRuleTags(
  List<RuleTagInput> rules, {
  required Set<String> reserved,
  required RuleConditionTable table,
  bool sideInlineSets = true,
}) {
  // п. 3 — базы раздаются всем до производных.
  final bases = <String>[];
  final takenBases = <String>{};
  for (final r in rules) {
    final b = ruleTagBase(r.name);
    var candidate = b;
    for (
      var i = 2;
      reserved.contains(candidate) || takenBases.contains(candidate);
      i++
    ) {
      candidate = '$b ($i)';
    }
    takenBases.add(candidate);
    bases.add(candidate);
  }

  // п. 5 — производный тег разводится суффиксом на самом теге, если совпал
  // с занятым, с базой любой записи или с уже выданным производным.
  final issued = <String>{};
  String derive(String tag) {
    var candidate = tag;
    for (
      var i = 2;
      reserved.contains(candidate) ||
          takenBases.contains(candidate) ||
          issued.contains(candidate);
      i++
    ) {
      candidate = '$tag ($i)';
    }
    issued.add(candidate);
    return candidate;
  }

  final out = <RuleTags>[];
  for (var i = 0; i < rules.length; i++) {
    final base = bases[i];
    final root = rules[i].root;
    if (root == null) {
      out.add(RuleTags(base: base));
      continue;
    }
    // §757 (контракт 1.1.182, D-158) — каждая ссылка `B':<stem>`; stem
    // совпал у разных ссылок правила или пуст — с хешем; совпадение h8
    // внутри группы одного stem — 16 hex у всей группы.
    final distinct = <String>[];
    for (final r in ruleTreeRefs(root)) {
      final t = r.trim();
      if (!distinct.contains(t)) distinct.add(t);
    }
    final byStem = <String, List<String>>{};
    for (final r in distinct) {
      (byStem[ruleRefStem(r)] ??= []).add(r);
    }
    final suffixOf = <String, String>{};
    for (final MapEntry(key: stem, value: group) in byStem.entries) {
      if (stem.isNotEmpty && group.length == 1) {
        suffixOf[group.single] = stem;
        continue;
      }
      final h8 = group.map(ruleRefHash).toSet();
      final len = h8.length < group.length ? 16 : 8;
      for (final r in group) {
        final h = ruleRefHash(r, length: len);
        suffixOf[r] = stem.isEmpty ? h : '$stem-$h';
      }
    }

    final refTags = <String, String>{};
    final inlineTags = <String, String>{};
    final rootIsLeaf = root is RuleLeaf;
    for (final (path, leaf) in ruleTreeLeaves(root)) {
      final atRoot = rootIsLeaf && path.isEmpty;
      for (final raw in leaf.refs) {
        final r = raw.trim();
        if (refTags.containsKey(r)) continue; // одна ссылка — один тег
        refTags[r] = derive('$base:${suffixOf[r]}');
      }
      if (ruleLeafHasInlineSet(leaf, table, sideInlineSets: sideInlineSets)) {
        final key = ruleTreePath(path);
        // Inline-набор корневого простого правила — чистый `B'` (со
        // ссылками и без); листа — `B':inline:<путь>`.
        inlineTags[key] = atRoot ? base : derive('$base:inline:$key');
      }
    }
    out.add(
      RuleTags(
        base: base,
        refTags: Map.unmodifiable(refTags),
        inlineTags: Map.unmodifiable(inlineTags),
      ),
    );
  }
  return out;
}
