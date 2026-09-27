import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/services/networks_direction.dart';
import 'package:lxbox/vpn/cc_channel.dart';
import 'package:lxbox/widgets/node_row.dart';
import 'package:lxbox/widgets/node_view_item.dart';

import '../contract_paths.dart';

/// Задача 579 — псевдо-направление NETWORKS: состав, состояние узла, строка.
void main() {
  setUpAll(loadTestRegistry);

  String config({
    List<Map<String, dynamic>> endpoints = const [],
    List<Map<String, dynamic>> outbounds = const [],
  }) => jsonEncode({'outbounds': outbounds, 'endpoints': endpoints});

  const tsLan = {'type': 'tailscale', 'tag': 'ts-lan'};
  const tsExit = {'type': 'tailscale', 'tag': 'ts-exit', 'exit_node': 'srv'};
  const wg = {
    'type': 'wireguard',
    'tag': 'wg-link',
    'address': ['10.0.0.2/32'],
    'private_key': 'x',
    'peers': <Object>[],
  };

  group('состав NETWORKS', () {
    test('Tailscale без exit_node входит', () {
      final m = ParsedConfig.parse(config(endpoints: [tsLan]));
      expect(networksNodeTags(m), ['ts-lan']);
    });

    test('Tailscale с exit_node не входит', () {
      final m = ParsedConfig.parse(config(endpoints: [tsExit]));
      expect(networksNodeTags(m), isEmpty);
    });

    test('endpoint WireGuard вне групп не входит', () {
      final m = ParsedConfig.parse(config(endpoints: [wg, tsLan]));
      expect(networksNodeTags(m), ['ts-lan']);
    });

    test('tailscale в outbounds[] не входит (только endpoints[])', () {
      final m = ParsedConfig.parse(config(outbounds: [tsLan]));
      expect(networksNodeTags(m), isEmpty);
    });

    test('пустой итог — NETWORKS нет', () {
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configRaw: config(endpoints: [tsExit, wg]),
        groups: const ['vpn-1'],
        networksOpen: true,
      );
      expect(s.networksNodes, isEmpty);
      expect(s.showingNetworks, isFalse);
    });
  });

  group('показ NETWORKS', () {
    final raw = config(endpoints: [tsLan]);

    test('выбран NETWORKS при включённом VPN', () {
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configRaw: raw,
        groups: const ['vpn-1'],
        networksOpen: true,
      );
      expect(s.showingNetworks, isTrue);
    });

    test('выбрано настоящее направление — список направления', () {
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configRaw: raw,
        groups: const ['vpn-1'],
        selectedGroup: 'vpn-1',
      );
      expect(s.showingNetworks, isFalse);
    });

    test('настоящих направлений нет — одно псевдо-направление', () {
      final s = HomeState(tunnel: TunnelStatus.connected, configRaw: raw);
      expect(s.showingNetworks, isTrue);
    });

    test('VPN выключен — NETWORKS не показывается', () {
      final s = HomeState(configRaw: raw, networksOpen: true);
      expect(s.showingNetworks, isFalse);
    });

    test('выбор NETWORKS не трогает выбранное направление', () {
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configRaw: raw,
        groups: const ['vpn-1'],
        selectedGroup: 'vpn-1',
      ).copyWith(networksOpen: true);
      expect(s.selectedGroup, 'vpn-1');
      expect(s.showingNetworks, isTrue);
    });

    test('значение пункта не совпадает с тегом направления NETWORKS', () {
      expect(kNetworksDirectionValue, isNot(kNetworksLabel));
    });
  });

  group('состояние узла', () {
    CcTailscaleStatus st(String backend, [String text = '']) =>
        CcTailscaleStatus(
          tag: 'ts-lan',
          backendState: backend,
          stateText: text,
        );
    TailnetRowState of(bool up, Map<String, CcTailscaleStatus> byTag) =>
        tailnetRowState(tunnelUp: up, tag: 'ts-lan', byTag: byTag);

    test('VPN выключен — состояния нет', () {
      expect(of(false, {'ts-lan': st('Running')}).kind, TailnetStateKind.none);
    });
    test('записи от ядра ещё нет — starting', () {
      expect(of(true, const {}).kind, TailnetStateKind.starting);
    });
    test('Running', () {
      expect(
        of(true, {'ts-lan': st('Running')}).kind,
        TailnetStateKind.running,
      );
    });
    test('NeedsLogin — предупреждение', () {
      final r = of(true, {'ts-lan': st('NeedsLogin')});
      expect(r.kind, TailnetStateKind.signInNeeded);
      expect(r.isWarning, isTrue);
    });
    test('Stopped — предупреждение', () {
      final r = of(true, {'ts-lan': st('Stopped')});
      expect(r.kind, TailnetStateKind.stopped);
      expect(r.isWarning, isTrue);
    });
    test('прочее — StateText как есть', () {
      final r = of(true, {'ts-lan': st('Starting', 'Connecting to tailnet')});
      expect(
        r,
        const TailnetRowState(TailnetStateKind.other, 'Connecting to tailnet'),
      );
    });
  });

  group('сообщение канала', () {
    test('список map → записи, без тега отбрасываются', () {
      final list = CcTailscaleStatus.listFrom([
        {'tag': 'ts-lan', 'backend_state': 'Running', 'state_text': 'ok'},
        {'tag': '', 'backend_state': 'Stopped'},
        'мусор',
      ]);
      expect(list, hasLength(1));
      expect(list.single.tag, 'ts-lan');
      expect(list.single.backendState, 'Running');
      expect(list.single.stateText, 'ok');
    });
    test('не список — пусто', () {
      expect(CcTailscaleStatus.listFrom(null), isEmpty);
      expect(CcTailscaleStatus.listFrom({'tag': 'x'}), isEmpty);
    });
  });

  group('строка узла NETWORKS', () {
    NodeViewItem item(TailnetStateKind kind) => NodeViewItem(
      tag: 'ts-lan',
      active: false,
      highlighted: false,
      delay: null,
      pingBusy: false,
      tunnelUp: true,
      busy: false,
      urltestNow: null,
      hasDetour: false,
      protocolLabel: 'Tailscale',
      tailnetState: TailnetRowState(kind),
    );

    testWidgets('на месте задержки состояние, нажатие не выбирает узел', (
      tester,
    ) async {
      var activated = 0;
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NodeRow(
              item: item(TailnetStateKind.running),
              onHighlight: () => opened++,
              onActivate: () => activated++,
              onPing: () {},
            ),
          ),
        ),
      );
      expect(find.text('running'), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_outline), findsNothing);
      await tester.tap(find.byType(NodeRow));
      await tester.pump();
      expect(opened, 1);
      expect(activated, 0);
    });

    testWidgets('меню без замера и выбора узла', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NodeRow(
              item: item(TailnetStateKind.signInNeeded),
              onHighlight: () {},
              onActivate: () {},
              onPing: () {},
              onViewJson: () {},
            ),
          ),
        ),
      );
      expect(find.text('sign-in needed'), findsOneWidget);
      await tester.longPress(find.byType(NodeRow));
      await tester.pumpAndSettle();
      expect(find.text('Ping'), findsNothing);
      expect(find.text('Use this node'), findsNothing);
      expect(find.text('View details'), findsOneWidget);
    });
  });
}
