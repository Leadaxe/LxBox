import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/screens/stats_screen/routing_section.dart';
import 'package:lxbox/services/selector_info.dart';
import 'package:lxbox/services/traffic_profiler.dart';
import 'package:lxbox/vpn/cc_channel.dart';
import 'package:lxbox/widgets/node_row.dart';
import 'package:lxbox/widgets/node_view_item.dart';

/// Задача 672 — Направление показывается label'ом там, где есть маппинг
/// tag → label: шторка, строка члена-Направления на home, Stats/Live.
/// Tag неизменяем (P2) и остаётся рядом — для сверки с Debug API.
void main() {
  const labels = {'vpn-1': 'Germany', 'vpn-2': 'Work'};

  setUp(() => SelectorInfo.I.resetForTesting());
  tearDown(() => SelectorInfo.I.resetForTesting());

  group('шторка', () {
    test('селектор и route.final подписаны label', () {
      final l = HomeController.notificationLines(
        routeFinal: 'vpn-1',
        selectedGroup: 'vpn-1',
        activeInGroup: 'node',
        directionLabels: labels,
      );
      expect(l.text, 'Germany: node');
      expect(l.title, 'L×Box [final = Germany]');
    });

    test('без label — tag как раньше', () {
      final l = HomeController.notificationLines(
        routeFinal: 'direct',
        selectedGroup: 'vpn-9',
        activeInGroup: null,
        directionLabels: labels,
      );
      expect(l.text, 'vpn-9');
      expect(l.title, 'L×Box [final = direct]');
    });
  });

  group('Stats/Live', () {
    test('Chain: Направление → «label (tag)», узел — как есть', () {
      final rows = routingRows(
        route: '',
        rule: '',
        chain: const ['node', 'vpn-1'],
        detour: const [],
        labels: labels,
      );
      expect(rows.firstWhere((r) => r.label == 'Chain').value,
          'node / Germany (vpn-1)');
    });

    test('Chain из одного Направления', () {
      final rows = routingRows(
        route: '',
        rule: '',
        chain: const ['vpn-1'],
        detour: const [],
        labels: labels,
      );
      expect(rows.firstWhere((r) => r.label == 'Chain').value,
          'Germany (vpn-1)');
    });

    test('Detour: свёртка по сырому тегу, подпись label (tag)', () {
      SelectorInfo.I.setFallbackTags(['vpn-2']);
      final rows = routingRows(
        route: '',
        rule: '',
        chain: const [],
        detour: const ['vpn-2', 'WG', 'WARP in'],
        labels: labels,
      );
      expect(rows.firstWhere((r) => r.label == 'Detour').value,
          'WARP in → Work (vpn-2) (WG)');
    });

    test('routing-строка Conns ≡ Live с label', () {
      SelectorInfo.I.setFallbackTags(['vpn-2']);
      final c = CcConnection(
        id: 'c1',
        network: 'tcp',
        domain: 'a.com',
        destination: '',
        rule: '',
        uplink: 0,
        downlink: 0,
        outbound: 'node',
        chains: const ['node', 'vpn-1'],
        detours: const ['vpn-2', 'WG'],
        createdAt: 1,
        closedAt: 0,
      );
      final e = TrafficEvent(
        ts: DateTime(2026),
        kind: TrafficEventKind.tcpOpen,
        domain: 'a.com',
        network: 'tcp',
        outboundChain: const ['node', 'vpn-1'],
        detourChain: const ['vpn-2', 'WG'],
      );
      const expected =
          'final ⇒ Germany (vpn-1) : Work (vpn-2) (WG) → Germany (vpn-1) (node) → a.com';
      expect(c.routingLineOf(compact: true, labels: labels), expected);
      expect(e.routingLineOf(compact: true, labels: labels), expected);
      // Без карты (dump, Debug) — сырые теги.
      expect(c.routingLineOf(compact: true),
          'final ⇒ vpn-1 : vpn-2 (WG) → vpn-1 (node) → a.com');
    });
  });

  testWidgets('home: член-Направление — label заголовком, tag в подзаголовке',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NodeRow(
          item: const NodeViewItem(
            tag: 'vpn-2',
            displayLabel: 'Work',
            active: false,
            highlighted: false,
            delay: null,
            pingBusy: false,
            tunnelUp: true,
            busy: false,
            urltestNow: null,
            hasDetour: false,
            outboundType: 'selector',
            protocolLabel: 'vpn-2',
          ),
          onHighlight: () {},
          onActivate: () {},
          onPing: () {},
        ),
      ),
    ));
    expect(find.text('Work'), findsOneWidget);
    expect(find.textContaining('vpn-2'), findsOneWidget);
  });
}
