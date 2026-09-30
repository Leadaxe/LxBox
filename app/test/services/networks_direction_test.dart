import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/screens/home/widgets/nodes_header.dart';
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

  group('заголовок списка при NETWORKS', () {
    final raw = config(endpoints: [tsLan]);
    final nodes = List.generate(21, (i) => 'n$i');

    test('счётчик — узлы NETWORKS, кнопок сортировки и фильтров нет', () {
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configRaw: raw,
        groups: const ['vpn-1'],
        selectedGroup: 'vpn-1',
        nodes: nodes,
        networksOpen: true,
      );
      expect(NodesHeader.listCount(s), 1);
      expect(NodesHeader.showsListTools(s), isFalse);
    });

    test('настоящее направление — его узлы и кнопки', () {
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configRaw: raw,
        groups: const ['vpn-1'],
        selectedGroup: 'vpn-1',
        nodes: nodes,
      );
      expect(NodesHeader.listCount(s), 21);
      expect(NodesHeader.showsListTools(s), isTrue);
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

  group('§608 exit node и срок ключа', () {
    final now = DateTime.utc(2026, 9, 30, 12);
    int at(Duration d) => now.add(d).millisecondsSinceEpoch ~/ 1000;

    CcTailscaleStatus status({
      CcTailscalePeer? exit,
      int keyExpiry = 0,
      String state = 'Running',
    }) => CcTailscaleStatus(
      tag: 'ts',
      backendState: state,
      stateText: '',
      self: CcTailscalePeer(hostName: 'me', keyExpiry: keyExpiry),
      exitNode: exit,
    );

    TailnetNote? note(CcTailscaleStatus? s, {bool withExit = true}) =>
        tailnetRowNote(tunnelUp: true, s: s, now: now, withExit: withExit);

    test('подписка: узлы с exit и NETWORKS, без WireGuard', () {
      final m = ParsedConfig.parse(config(endpoints: [wg, tsExit, tsLan]));
      expect(tailscaleNodeTags(m), ['ts-exit', 'ts-lan']);
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configRaw: config(endpoints: [tsExit]),
      );
      expect(s.networksNodes, isEmpty);
      expect(s.tailscaleNodes, ['ts-exit']);
    });

    test('имя exit node: hostName → метка DNS → IP', () {
      expect(tailnetExitName(null), isNull);
      expect(tailnetExitName(status()), isNull);
      expect(
        tailnetExitName(status(exit: const CcTailscalePeer(hostName: 'nas'))),
        'nas',
      );
      expect(
        tailnetExitName(
          status(exit: const CcTailscalePeer(dnsName: 'box.tail1.ts.net.')),
        ),
        'box',
      );
      expect(
        tailnetExitName(status(exit: const CcTailscalePeer(ips: ['100.1.2.3']))),
        '100.1.2.3',
      );
    });

    test('exit node офлайн важнее срока ключа; у NETWORKS не бывает', () {
      final s = status(
        exit: const CcTailscalePeer(hostName: 'nas'),
        keyExpiry: at(const Duration(days: 2)),
      );
      expect(note(s), const TailnetNote(TailnetNoteKind.exitOffline));
      expect(
        note(s, withExit: false),
        const TailnetNote(TailnetNoteKind.keyExpires, 2),
      );
      final online = status(
        exit: const CcTailscalePeer(hostName: 'nas', online: true),
      );
      expect(note(online), isNull);
    });

    test('срок ключа: отключён, далеко, дни, меньше суток, истёк', () {
      expect(note(status()), isNull);
      expect(note(status(keyExpiry: at(const Duration(days: 8)))), isNull);
      expect(
        note(status(keyExpiry: at(const Duration(days: 3, hours: 12)))),
        const TailnetNote(TailnetNoteKind.keyExpires, 3),
      );
      expect(
        note(status(keyExpiry: at(const Duration(hours: 5)))),
        const TailnetNote(TailnetNoteKind.keyExpires, 0),
      );
      expect(
        note(status(keyExpiry: at(const Duration(hours: -1)))),
        const TailnetNote(TailnetNoteKind.keyExpired),
      );
    });

    test('VPN выключен или записи нет — метки нет', () {
      final s = status(keyExpiry: at(const Duration(hours: 5)));
      expect(
        tailnetRowNote(tunnelUp: false, s: s, now: now, withExit: true),
        isNull,
      );
      expect(note(null), isNull);
    });

    NodeViewItem row({
      TailnetRowState? tailnetState,
      String endpointState = '',
      required TailnetNote note,
    }) => NodeViewItem(
      tag: 'ts',
      active: false,
      highlighted: false,
      delay: null,
      pingBusy: false,
      tunnelUp: true,
      busy: false,
      urltestNow: null,
      hasDetour: false,
      protocolLabel: 'Tailscale·via nas',
      endpointState: endpointState,
      tailnetState: tailnetState,
      tailnetNote: note,
    );

    Future<void> pump(WidgetTester tester, NodeViewItem item) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NodeRow(
                item: item,
                onHighlight: () {},
                onActivate: () {},
                onPing: () {},
              ),
            ),
          ),
        );

    testWidgets('узел с exit: метка на месте up, но не off', (tester) async {
      await pump(
        tester,
        row(
          endpointState: CcEndpointState.up,
          note: const TailnetNote(TailnetNoteKind.exitOffline),
        ),
      );
      expect(find.text('exit offline'), findsOneWidget);
      expect(find.text('up'), findsNothing);
      await pump(
        tester,
        row(
          endpointState: CcEndpointState.disabled,
          note: const TailnetNote(TailnetNoteKind.keyExpires, 3),
        ),
      );
      expect(find.text('off'), findsOneWidget);
      expect(find.text('key expires 3d'), findsNothing);
    });

    testWidgets('NETWORKS: ключ вместо running, sign-in важнее', (
      tester,
    ) async {
      await pump(
        tester,
        row(
          tailnetState: const TailnetRowState(TailnetStateKind.running),
          note: const TailnetNote(TailnetNoteKind.keyExpires, 0),
        ),
      );
      expect(find.text('key expires <1d'), findsOneWidget);
      expect(find.text('running'), findsNothing);
      await pump(
        tester,
        row(
          tailnetState: const TailnetRowState(TailnetStateKind.signInNeeded),
          note: const TailnetNote(TailnetNoteKind.keyExpired),
        ),
      );
      expect(find.text('sign-in needed'), findsOneWidget);
      expect(find.text('key expired'), findsNothing);
    });
  });
}
