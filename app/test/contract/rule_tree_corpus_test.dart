import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart' show RuleDns;
import 'package:lxbox/models/rule_tree.dart';
import 'package:lxbox/services/builder/post_steps.dart' show dnsMirrorRule;
import 'package:lxbox/services/builder/rule_tree_emit.dart';
import 'package:lxbox/services/builder/rule_tree_tags.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/contract/rule_conditions.dart';

import '../contract_paths.dart';

// §757 — конформанс-раннер корпуса выпуска правила-дерева (контракт 1.1.179,
// TASKS_LXBOX §182; нормы TEMPLATE_LANG §6.13 и §6.11), сторона LxBox. Тот
// же набор гоняет лаунчер (`core/build/contract_rule_tree_test.go`).
//
// Записи `rules[]` → разбор тела в дерево → теги оси → выпуск наборов,
// маршрута и зеркал (с выбором стороны: ключи `set: true` узла без `refs`
// уходят в inline-набор). До сравнения такой набор сворачивается обратно в
// узел (README корпуса), а его тег проверяется: у корня — `B'`, у листа —
// `B':inline:<путь>`. Порядок ключей не нормативен, порядок записей — да.

/// Кейсы, ожидаемо расходящиеся с нормой (кейс → причина).
const Map<String, String> _pendingCases = {};

const _treeKinds = {'inline', 'srs'};

void main() {
  if (corpusSuiteUnavailable('test/contract/rule_tree_corpus_test.dart')) {
    return;
  }

  setUpAll(loadTestRegistry);

  final root = Directory('$kVendorRoot/corpus/rule_tree');
  if (!root.existsSync()) return; // контракт не синхронизирован

  final cases =
      root
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.rules.json'))
          .map((f) => f.path.substring(0, f.path.length - '.rules.json'.length))
          .toList()
        ..sort();

  group('contract corpus: rule_tree', () {
    test('корпус не пуст', () => expect(cases, isNotEmpty));

    for (final base in cases) {
      final name = base.substring(root.path.length + 1);
      test(name, skip: _pendingCases[name], () {
        final input =
            jsonDecode(File('$base.rules.json').readAsStringSync())
                as Map<String, dynamic>;
        final expected =
            jsonDecode(File('$base.expected.json').readAsStringSync())
                as Map<String, dynamic>;
        final table = ContractRegistry.I.ruleConditions;
        expect(table, isNotNull, reason: 'в реестре нет rule_conditions.json');
        final actual = _runCase(input, table!);
        for (final key in ['rule_set', 'route_rules', 'dns_rules']) {
          final want = expected[key] as List;
          expect(
            const DeepCollectionEquality().equals(actual[key], want),
            isTrue,
            reason:
                '$key\nполучено: ${jsonEncode(actual[key])}\n'
                'ожидалось: ${jsonEncode(want)}',
          );
        }
        expect(
          actual['mirror_empty'],
          (expected['mirror_empty'] as List?) ?? const [],
        );
      });
    }
  });
}

Map<String, List<Object?>> _runCase(
  Map<String, dynamic> input,
  RuleConditionTable table,
) {
  final records = [
    for (final r in input['rules'] as List) Map<String, dynamic>.from(r as Map),
  ];
  // Порядок оси — по `num` (стабильно).
  final indexed = [for (var i = 0; i < records.length; i++) (i, records[i])];
  indexed.sort((a, b) {
    final c = ((a.$2['num'] as num?) ?? 0).compareTo(
      (b.$2['num'] as num?) ?? 0,
    );
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  final axis = [
    for (final e in indexed)
      if (_treeKinds.contains(e.$2['kind'])) e.$2,
  ];

  final reserved = <String>{
    ...((input['template_rule_set_tags'] as List?) ?? const []).cast<String>(),
    for (final tags
        in ((input['preset_rule_set_tags'] as Map?) ?? const {}).values)
      ...(tags as List).cast<String>(),
  };

  final bodies = [
    for (final r in axis)
      r['body'] is Map
          ? parseRuleTreeBody(
              Map<String, dynamic>.from(r['body'] as Map),
              table,
              recordRefs: legacyRecordRefs(r),
            )
          : null,
  ];
  final tags = assignRuleTags(
    [
      for (var i = 0; i < axis.length; i++)
        RuleTagInput(
          name: (axis[i]['name'] as String?) ?? '',
          root: bodies[i]?.root,
        ),
    ],
    reserved: reserved,
    table: table,
  );

  final ruleSets = <Map<String, dynamic>>[];
  final routeRules = <Map<String, dynamic>>[];
  final dnsRules = <Map<String, dynamic>>[];
  final mirrorEmpty = <String>[];
  final emittedTags = <String>{...reserved};
  final emitted =
      <(Map<String, dynamic>, RuleTreeBody, RuleTags, RuleTreeEmitResult)>[];

  for (var i = 0; i < axis.length; i++) {
    final record = axis[i];
    final body = bodies[i];
    expect(
      body,
      isNotNull,
      reason: 'тело правила "${record['name']}" не разобрано деревом',
    );
    if (record['enabled'] == false) continue;
    final res = emitRuleTree(
      ruleName: (record['name'] as String?) ?? '',
      body: body!,
      tags: tags[i],
      // Все наборы считаются скачанными.
      refPath: (r) => '/corpus/${ruleRefHash(r)}.srs',
      table: table,
    );
    expect(
      res.emitted,
      isTrue,
      reason: 'правило "${record['name']}" не выпущено: ${res.warnings}',
    );
    for (final s in res.ruleSets) {
      emittedTags.add(s['tag'] as String);
    }
    emitted.add((record, body, tags[i], res));
  }

  for (final (record, body, ruleTags, res) in emitted) {
    final ruleName = (record['name'] as String?) ?? '';
    expect(
      ruleTreeDanglingTags(body.root, emittedTags),
      isEmpty,
      reason: 'висячий рукописный rule_set у "$ruleName"',
    );

    final matcher = ruleTreeMirrorMatcher(res.match!, res.inlineSets, table);
    final mirrors = ruleTreeDnsMirrors(
      ruleId: ruleName,
      ruleName: ruleName,
      enabled: true,
      dns: RuleDns.fromJson(record['dns']),
      mirror: matcher,
      hasRefsOrDomain: ruleTreeHasRefsOrDomain(body.root, table),
    );
    if (mirrors.emptyWithDnsOption) mirrorEmpty.add(ruleName);
    final servers = {
      for (final m in mirrors.entries)
        if (m.serverTag.isNotEmpty) m.serverTag,
    };
    final ruleDns = [
      for (final m in mirrors.entries) ?dnsMirrorRule(m, servers),
    ];

    // Свёртка inline-наборов выбора стороны (узел без `refs`) обратно в
    // узел. Тег проверяется до свёртки.
    final route = res.routeRule!;
    final folded = <String>{};
    for (final s in res.inlineSets) {
      if (s.nodeHasRefs) continue;
      final want = s.path.isEmpty
          ? ruleTags.base
          : '${ruleTags.base}:inline:${s.path}';
      expect(
        s.tag,
        want,
        reason:
            'тег inline-набора узла без refs у "$ruleName" '
            '(путь "${s.path}")',
      );
      folded.add(s.tag);
      _foldTag(route, s.tag, s.keys);
      final dnsKeys = {
        for (final e in s.keys.entries)
          if (table.key(e.key)?.dns ?? false) e.key: e.value,
      };
      for (final d in ruleDns) {
        _foldTag(d, s.tag, dnsKeys);
      }
    }
    for (final s in res.ruleSets) {
      if (folded.contains(s['tag'])) continue;
      ruleSets.add({
        for (final e in s.entries)
          if (e.key != 'path' && e.key != 'url') e.key: e.value,
      });
    }
    routeRules.add(route);
    dnsRules.addAll(ruleDns);
  }

  return {
    'rule_set': ruleSets,
    'route_rules': routeRules,
    'dns_rules': dnsRules,
    'mirror_empty': mirrorEmpty,
  };
}

/// Тег [tag] в `rule_set` любого узла → ключи [keys] на месте тега.
void _foldTag(Map<String, dynamic> node, String tag, Map<String, Object> keys) {
  final rs = node['rule_set'];
  final list = switch (rs) {
    final String s => [s],
    final List l => l.cast<String>().toList(),
    _ => <String>[],
  };
  if (list.remove(tag)) {
    if (list.isEmpty) {
      node.remove('rule_set');
    } else {
      node['rule_set'] = list.length == 1 ? list.first : list;
    }
    node.addAll(keys);
  }
  for (final c in (node['rules'] as List?) ?? const []) {
    if (c is Map<String, dynamic>) _foldTag(c, tag, keys);
  }
}
