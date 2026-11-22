/// §757 — теги наборов собственных правил (TEMPLATE_LANG §6.13 «Теги
/// наборов», контракт 1.1.179, D-157): одна схема у LxBox и лаунчера.
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
    // Коллизия h8 внутри правила — у обеих ссылок 16 hex.
    final distinct = ruleTreeRefs(root).map((r) => r.trim()).toList();
    final h8Count = <String, int>{};
    for (final r in distinct) {
      final h = ruleRefHash(r);
      h8Count[h] = (h8Count[h] ?? 0) + 1;
    }
    String hashOf(String r) {
      final h = ruleRefHash(r);
      return (h8Count[h] ?? 0) > 1 ? ruleRefHash(r, length: 16) : h;
    }

    final refTags = <String, String>{};
    final inlineTags = <String, String>{};
    final rootIsLeaf = root is RuleLeaf;
    var firstRootRef = true;
    for (final (path, leaf) in ruleTreeLeaves(root)) {
      final atRoot = rootIsLeaf && path.isEmpty;
      for (final raw in leaf.refs) {
        final r = raw.trim();
        if (refTags.containsKey(r)) continue; // одна ссылка — один тег
        if (atRoot && firstRootRef) {
          // Первая ссылка корневого простого правила — сама `B'`.
          refTags[r] = base;
        } else {
          refTags[r] = derive('$base:${hashOf(r)}');
        }
        if (atRoot) firstRootRef = false;
      }
      if (ruleLeafHasInlineSet(leaf, table, sideInlineSets: sideInlineSets)) {
        final key = ruleTreePath(path);
        if (atRoot) {
          // Корень без ссылок — набор берёт `B'`; со ссылками — `B':inline`.
          inlineTags[key] = leaf.refs.isEmpty ? base : derive('$base:inline');
        } else {
          inlineTags[key] = derive('$base:inline:$key');
        }
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
