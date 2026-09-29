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
/// Тело разбора называет членов слагом лаунчера (`xrayGroupMemberRef`), а
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

  test('duplicates_collapsed_owner: члены группы «Авто» — реальные теги',
      () async {
    final nodes = parseAll(decode(corpusBody(
        'contract/corpus/body/xray/duplicates_collapsed_owner.body')));
    final auto = nodes.whereType<AutoSelectSpec>().single;

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

    final all = [
      ...(r.config['outbounds'] as List? ?? const []),
      ...(r.config['endpoints'] as List? ?? const []),
    ].cast<Map<String, dynamic>>();
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
}
