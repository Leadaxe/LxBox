// Фича 478 — обратная карта тегов: хоп родной цепочки → владелец (№6).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart' show WizardTemplate, ParserConfigBlock, GroupTemplates, DirectionTemplate, AutoTemplate, DefaultDirection;
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import '../parser/engine_test_setup.dart';

void main() {
  setUpAll(() async {
    loadEngineSections();
    if (Directory('assets/contract/registry').existsSync()) {
      await ContractRegistry.I.loadFromDirectory('assets/contract');
    }
  });

  final template = WizardTemplate(
    parserConfig: ParserConfigBlock(),
    groupTemplates: GroupTemplates(
      direction: DirectionTemplate(
        include: const ['direct', 'auto'],
        options: const {'interrupt_exist_connections': true},
      ),
      auto: AutoTemplate(
        options: const {'url': 'https://x', 'interval': '30s'},
      ),
      defaultDirections: [
        DefaultDirection(tag: 'vpn-1', label: 'vpn-1', defaultEnabled: true),
      ],
    ),
    vars: const [],
    varSections: const [],
    config: {
      'outbounds': [
        {'tag': 'direct-out', 'type': 'direct'},
      ],
      'route': {'rules': []},
    },
    selectableRules: const [],
    dnsOptions: const {},
    pingOptions: const {},
    speedTestOptions: const {},
  );

  test('тег хопа цепочки в nodeByEmittedTag ведёт к владельцу', () async {
    final main =
        parseUri('vless://11111111-1111-1111-1111-111111111111@main:443?type=ws&security=tls#Main')!;
    final hop =
        parseUri('vless://22222222-2222-2222-2222-222222222222@hop:443?type=ws&security=tls#hop-link')!;
    final owner = withChained(main, hop);
    final list = SubscriptionServers(
      id: 's1',
      name: 'Sub',
      enabled: true,
      tagPrefix: 'vpn-1',
      detourPolicy: DetourPolicy.defaults,
      url: 'https://example.com/sub',
      nodes: [owner],
    );

    final result = await buildConfig(
      lists: [list],
      template: template,
      settings: const BuildSettings(
        userVars: {'clash_api': '127.0.0.1:9090'},
        enabledGroups: {'vpn-1', kAutoOutboundTag},
      ),
    );

    final hopEntry = (result.config['outbounds'] as List)
        .cast<Map>()
        .firstWhere((o) => (o['tag'] as String).contains('hop-link'));
    final hopTag = hopEntry['tag'] as String;
    final mainTag = result.nodeByEmittedTag.entries
        .firstWhere((e) => identical(e.value, owner))
        .key;

    expect(result.nodeByEmittedTag[hopTag], owner);
    expect(result.nodeByEmittedTag[mainTag], owner);
  });
}
