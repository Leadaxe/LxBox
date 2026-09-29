import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import '../parser/engine_test_setup.dart';

/// §322 — группа Xray-элемента, все члены которой отданы другим элементам
/// правилом владения (§342, корпус `body/xray/duplicates_collapsed_owner`).
/// Тело разбора называет членов по label узла (§101, 1.1.104), а
/// итоговый состав группы строит сборка по правилу `selector` и синонимам
/// пула (`resolveAutoSelectMembers`): в конфиге группа не пуста и каждый её
/// член — существующий outbound/endpoint.
void main() {
  setUpAll(loadEngineSections);

  String corpusBody(String rel) {
    final lines = File(rel).readAsStringSync().split('\n');
    var start = 0;
    while (start < lines.length && lines[start].trimLeft().startsWith('#')) {
      start++;
    }
    return lines.skip(start).join('\n');
  }

  Future<List<Map<String, dynamic>>> buildAll(List<NodeSpec> nodes) async {
    final r = await buildConfig(
      lists: [
        UserServer(
          id: 'sub',
          name: 'Sub',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: UserSource.paste,
          nodes: nodes,
        ),
      ],
      template: WizardTemplate(
        parserConfig: ParserConfigBlock(),
        groupTemplates: GroupTemplates(),
        vars: const [],
        varSections: const [],
        config: {
          'outbounds': [
            {'tag': 'direct-out', 'type': 'direct'},
            {'tag': 'block', 'type': 'block'},
          ],
          'route': {'rules': []},
        },
        selectableRules: const [],
        dnsOptions: const {},
        pingOptions: const {},
        speedTestOptions: const {},
      ),
      settings: const BuildSettings(
        directions: [Direction(tag: 'vpn-1', label: 'X')],
      ),
    );
    expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
    return [
      ...(r.config['outbounds'] as List? ?? const []),
      ...(r.config['endpoints'] as List? ?? const []),
    ].cast<Map<String, dynamic>>();
  }

  test('duplicates_collapsed_owner: члены группы «Авто» — реальные теги',
      () async {
    final nodes = parseAll(decode(corpusBody(
        'contract/corpus/body/xray/duplicates_collapsed_owner.body')));
    final auto = nodes.whereType<AutoSelectSpec>().single;

    final all = await buildAll(nodes);
    final tags = {for (final o in all) o['tag']};
    final group = all.firstWhere((o) => o['tag'] == auto.tag);
    final members = (group['outbounds'] as List).cast<String>();

    expect(members, isNotEmpty);
    for (final m in members) {
      expect(tags, contains(m), reason: 'член $m — не тег конфига');
    }
    // Оба сервера пула (a — у «Австрии», b — у «Польши») в группе.
    expect(members, containsAll(['🇦🇹 Австрия', '🇵🇱 Польша']));
  });

  // Контракт 1.1.106 — повторённый `tag` и запись без `tag` в пуле: группа
  // в конфиге держит все три сервера, ни один не теряется.
  test('balancer_pool_labels_taken: группа держит все три сервера', () async {
    final nodes = parseAll(decode(corpusBody(
        'contract/corpus/body/xray/balancer_pool_labels_taken.body')));
    final auto = nodes.whereType<AutoSelectSpec>().single;
    final servers = nodes.where((n) => n is! AutoSelectSpec).toList();
    expect(servers.map((n) => n.label), ['pool p', 'pool p 2', 'pool 3']);

    final all = await buildAll(nodes);
    final tags = {for (final o in all) o['tag']};
    final group = all.firstWhere((o) => o['tag'] == auto.tag);
    final members = (group['outbounds'] as List).cast<String>();
    for (final m in members) {
      expect(tags, contains(m), reason: 'член $m — не тег конфига');
    }
    expect(members.toSet(), {for (final n in servers) n.tag});
  });

  // Контракт 1.1.107 — пул по `selector`: префикс `px` выбирает `px-1` и
  // `px-2`; `other` остаётся узлом элемента, но в группу не входит.
  test('balancer_selector_subset: в группе ровно pool px-1, pool px-2',
      () async {
    final nodes = parseAll(decode(corpusBody(
        'contract/corpus/body/xray/balancer_selector_subset.body')));
    final auto = nodes.whereType<AutoSelectSpec>().single;
    final servers = nodes.where((n) => n is! AutoSelectSpec).toList();
    expect(servers.map((n) => n.label), ['pool px-1', 'pool px-2', 'pool other']);

    final all = await buildAll(nodes);
    final tags = {for (final o in all) o['tag']};
    expect(tags, contains(servers.last.tag),
        reason: 'невыбранный сервер — узел конфига');
    final group = all.firstWhere((o) => o['tag'] == auto.tag);
    final members = (group['outbounds'] as List).cast<String>();
    expect(members, [servers[0].tag, servers[1].tag]);
    expect(members, ['pool px-1', 'pool px-2']);
  });
}
