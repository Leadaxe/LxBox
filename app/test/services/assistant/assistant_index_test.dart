// §750 — сборка индекса ассистента для натива.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/assistant/assistant_index.dart';
import 'package:lxbox/services/settings_storage.dart';

import 'assistant_fixtures.dart';

void main() {
  group('buildAssistantIndex', () {
    test('Направления: все, подпись без ⚙, пустая подпись → тег', () {
      final idx = buildAssistantIndex(
        directions: const [
          Direction(tag: 'vpn-1', label: 'Proxy'),
          Direction(tag: 'vpn-2', label: 'Work', enabled: false),
          Direction(tag: 'hop', label: '⚙ Hop', isDetour: true),
          Direction(tag: 'vpn-3', label: ''),
        ],
        rules: const [],
        lists: const [],
        routeFinal: '',
      );
      expect(idx['v'], 1);
      expect(idx['route_final'], 'vpn-1', reason: 'пусто читается как vpn-1');
      expect(idx['directions'], [
        {'tag': 'vpn-1', 'name': 'Proxy', 'enabled': true},
        {'tag': 'vpn-2', 'name': 'Work', 'enabled': false},
        {'tag': 'hop', 'name': 'Hop', 'enabled': true},
        {'tag': 'vpn-3', 'name': 'vpn-3', 'enabled': true},
      ]);
      // Индекс уходит строкой JSON.
      expect(() => jsonEncode(idx), returnsNormally);
    });

    test('route_final как записан (direct-out, block, тег)', () {
      for (final f in ['direct-out', 'block', 'vpn-2']) {
        final idx = buildAssistantIndex(
            directions: const [], rules: const [], lists: const [],
            routeFinal: f);
        expect(idx['route_final'], f);
      }
    });

    test('подключения всех видов источников, включая выключенные', () {
      final office = wgNode('Office');
      final home = wgNode('Home', awg: true);
      final ovpn = unknownNode('Corp VPN', 'openvpn-client');
      final oc = unknownNode('Forti', 'openconnect');
      final ts = tsNode('Tailnet');
      final subWg = wgNode('Sub WG');
      final subOff = wgNode('Sub WG off');
      final idx = buildAssistantIndex(
        directions: const [],
        rules: const [],
        routeFinal: 'vpn-1',
        lists: [
          userServer('u1', office, enabled: false),
          folder('f1', 'Work', [
            member(home),
            member(ovpn, enabled: false),
            member(unknownNode('future', 'future-proto')),
          ]),
          folder('f2', 'Off folder', [member(oc)], enabled: false),
          userServer('u2', ts),
          subscription('s1', [subWg, subOff],
              tagPrefix: 'Prov', disabled: {'Sub WG off': DateTime.utc(2026)}),
        ],
      );
      expect(idx['connections'], [
        {'id': 'Office', 'name': 'Office', 'type': 'wireguard', 'enabled': false},
        {'id': 'Home', 'name': 'Home', 'type': 'amneziawg', 'enabled': true},
        {'id': 'Corp VPN', 'name': 'Corp VPN', 'type': 'openvpn', 'enabled': false},
        {'id': 'Forti', 'name': 'Forti', 'type': 'openconnect', 'enabled': false},
        {'id': 'Tailnet', 'name': 'Tailnet', 'type': 'tailscale', 'enabled': true},
        {'id': 'Prov Sub WG', 'name': 'Sub WG', 'type': 'wireguard', 'enabled': true},
        {'id': 'Prov Sub WG off', 'name': 'Sub WG off', 'type': 'wireguard', 'enabled': false},
      ]);
    });

    test('id берётся из карты последней сборки (переименованный тёзка)', () {
      final a = wgNode('Office');
      final conns = assistantConnections(
        [userServer('u1', a)],
        emittedTagMap: <String, NodeSpec>{'Office-2': a},
      );
      expect(conns.single.id, 'Office-2');
    });

    test('app_rules: порядок применения, выключенные и без пакетов отброшены, '
        'conditional', () {
      final rules = <CustomRule>[
        CustomRuleTree.flat(
            name: 'Later', orderNum: 1005, packages: ['b.app'], outbound: 'vpn-2'),
        CustomRuleTree.flat(
            name: 'First',
            orderNum: 1001,
            packages: ['a.app'],
            outbound: 'direct-out'),
        CustomRuleTree.flat(
            name: 'Off', orderNum: 1000, enabled: false, packages: ['c.app']),
        CustomRuleTree.flat(
            name: 'Domains only', orderNum: 1002, domains: ['example.com']),
        CustomRuleTree.flat(
            name: 'Regex + Wi-Fi',
            orderNum: 1003,
            packageRegexes: [r'^org\.example\.'],
            wifiSsids: ['Office'],
            outbound: 'reject'),
        CustomRuleTree.flat(
            name: 'Set',
            orderNum: 1004,
            // §757 — правило с набором: вид srs выводится из ссылок.
            srsUrl: 'https://x/set.srs',
            packages: ['d.app'],
            outbound: 'vpn-1'),
        CustomRulePreset(
            name: 'Preset', orderNum: 900, presetId: 'p', varsValues: {
          'outbound': 'vpn-2',
        }),
      ];
      final idx = buildAssistantIndex(
          directions: const [], rules: rules, lists: const [], routeFinal: '');
      expect(idx['app_rules'], [
        {
          'name': 'First',
          'packages': ['a.app'],
          'package_regexes': <String>[],
          'outbound': 'direct-out',
          'conditional': false,
        },
        {
          'name': 'Regex + Wi-Fi',
          'packages': <String>[],
          'package_regexes': [r'^org\.example\.'],
          'outbound': 'reject',
          'conditional': true,
        },
        {
          'name': 'Set',
          'packages': ['d.app'],
          'package_regexes': <String>[],
          'outbound': 'vpn-1',
          'conditional': true,
        },
        {
          'name': 'Later',
          'packages': ['b.app'],
          'package_regexes': <String>[],
          'outbound': 'vpn-2',
          'conditional': false,
        },
      ]);
    });
  });

  test('collectAssistantIndex: собирает из хранилища в момент вызова',
      () async {
    await setUpTempStorage();
    await SettingsStorage.setDirections(
        [const Direction(tag: 'vpn-1', label: 'Proxy')]);
    await SettingsStorage.saveRouteFinal('direct-out');
    final idx = await collectAssistantIndex(
      lists: [userServer('u1', wgNode('Office'))],
      emittedTagMap: const {},
    );
    expect(idx['route_final'], 'direct-out');
    expect((idx['directions'] as List).single['name'], 'Proxy');
    expect((idx['connections'] as List).single['id'], 'Office');
  });
}
