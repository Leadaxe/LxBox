import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/subscription/node_budget.dart';

import '../parser/engine_test_setup.dart';

/// Бюджет узлов: раздача между подписками и обрезка выдачи.
void main() {
  setUpAll(loadEngineSections);

  SubscriptionServers sub(String id, int size, {bool enabled = true}) =>
      SubscriptionServers(
        id: id,
        name: id,
        enabled: enabled,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'http://x/$id',
        lastNodeCount: size,
      );

  List<NodeSpec> vless(int n, {String prefix = 'N'}) => parseAll(decode([
        for (var i = 0; i < n; i++)
          'vless://uuid-$i@h$i.example:443?type=ws&security=tls#$prefix$i',
      ].join('\n')));

  UserServer manual(int n) => UserServer(
        id: 'manual',
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        nodes: vless(n, prefix: 'M'),
      );

  test('(a) ручные 100, A=50, B=2000 → A 50, B 850', () {
    expect(splitNodeBudget(budget: 1000, manual: 100, sizes: [50, 2000]),
        [50, 850]);
  });

  test('(b) 10/10/5000 при бюджете 1000 → 10/10/980', () {
    expect(splitNodeBudget(budget: 1000, manual: 0, sizes: [10, 10, 5000]),
        [10, 10, 980]);
  });

  test('(c) ручные 1200 → всем 0', () {
    expect(splitNodeBudget(budget: 1000, manual: 1200, sizes: [10, 5000]),
        [0, 0]);
    expect(splitNodeBudget(budget: 1000, manual: 1000, sizes: [10]), [0]);
  });

  test('остаток от деления — подпискам по порядку списка', () {
    expect(splitNodeBudget(budget: 1000, manual: 0, sizes: [600, 600, 600]),
        [334, 333, 333]);
  });

  test('ручное считается по включённым серверам', () {
    final off = UserServer(
      id: 'off',
      name: '',
      enabled: false,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      nodes: vless(5, prefix: 'O'),
    );
    expect(countManualBudgetNodes([manual(3), off, sub('a', 10)]), 3);
  });

  test('(d) выключенная подписка не получает и не отнимает', () {
    final q = nodeBudgetQuotas(budget: 1000, sources: [
      manual(100),
      sub('a', 50),
      sub('off', 5000, enabled: false),
      sub('b', 2000),
    ]);
    expect(q, {'a': 50, 'b': 850});
    // Её разбирают (обновление выключенных) — тогда участвует.
    final withOff = nodeBudgetQuotas(
        budget: 1000,
        sources: [sub('a', 10), sub('off', 5000, enabled: false)],
        includeId: 'off');
    expect(withOff, {'a': 10, 'off': 990});
  });

  test('(e) защищённых больше доли → все защищённые', () {
    final nodes = vless(10);
    final cut = cutNodesToQuota(
      nodes,
      2,
      const SourceProtectedTags(rawTags: {'N3', 'N5', 'N7'}),
    );
    expect(cut.nodes.map((n) => n.tag), ['N3', 'N5', 'N7']);
    expect(cut.total, 10);
  });

  test('обрезка: защищённые первыми, добор по порядку, порядок выдачи', () {
    final cut = cutNodesToQuota(
        vless(10), 3, const SourceProtectedTags(rawTags: {'N8'}));
    expect(cut.nodes.map((n) => n.tag), ['N0', 'N1', 'N8']);
  });

  test('defaultFilter Направления защищает первый подходящий узел', () {
    final cut = cutNodesToQuota(
        vless(10), 1, const SourceProtectedTags(defaultPatterns: ['n[4-9]']));
    expect(cut.nodes.map((n) => n.tag), ['N4']);
  });

  test('цель detour за пределами доли остаётся', () {
    final target = sub('s', 10);
    final server = UserServer(
      id: 'srv',
      name: '',
      enabled: true,
      tagPrefix: '',
      detourPolicy: const DetourPolicy(
          overrideDetour: NodeLink(folderId: 's', tag: 'N9')),
      nodes: vless(1, prefix: 'M'),
    );
    final protected = collectProtectedNodeTags(
      directions: const [],
      chains: const [],
      rules: const [],
      sources: [server, target],
    ).forSource(target);
    final cut = cutNodesToQuota(vless(10), 2, protected);
    expect(cut.nodes.map((n) => n.tag), ['N0', 'N9']);
  });

  test('квота 0 — пусто, total сохраняется', () {
    final cut = cutNodesToQuota(vless(4), 0);
    expect(cut.nodes, isEmpty);
    expect(cut.total, 4);
  });
}
