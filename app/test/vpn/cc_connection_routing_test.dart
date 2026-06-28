import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/vpn/cc_channel.dart';
import 'package:lxbox/services/traffic_profiler.dart';

/// §204 — `CcConnection.routingLineOf` обязан давать строку, ИДЕНТИЧНУЮ
/// `TrafficEvent.routingLineOf` на тех же данных (один источник chains/detours
/// из ядра, нотация §181). Это гарантия унификации Conns ↔ Profiler.
void main() {
  CcConnection conn({
    String network = 'tcp',
    String domain = '',
    String destination = '',
    String rule = '',
    String outbound = '',
    List<String> chains = const [],
    List<String> detours = const [],
  }) =>
      CcConnection(
        id: 'c1',
        network: network,
        domain: domain,
        destination: destination,
        rule: rule,
        uplink: 0,
        downlink: 0,
        outbound: outbound,
        chains: chains,
        detours: detours,
        createdAt: 1,
        closedAt: 0,
      );

  TrafficEvent ev({
    String? network = 'tcp',
    String? domain,
    String? rule,
    List<String> outboundChain = const [],
    List<String> detourChain = const [],
  }) =>
      TrafficEvent(
        ts: DateTime(2026),
        kind: TrafficEventKind.tcpOpen,
        domain: domain,
        network: network,
        rule: rule,
        outboundChain: outboundChain,
        detourChain: detourChain,
        // duration НЕ задаём — TrafficEvent добавляет `· dur` только при наличии;
        // CcConnection его не пишет вовсе (§204 D). Сравниваем без duration.
      );

  group('§204 — routingLineOf 1:1 Conn ↔ Event', () {
    test('канал с auto-двойником: rule final, chains [node, auto, vpn-1]', () {
      final c = conn(
        domain: 'spotify.com',
        chains: ['✨auto', 'vpn-1'],
        outbound: '✨auto',
      );
      final e = ev(
        domain: 'spotify.com',
        outboundChain: ['✨auto', 'vpn-1'],
      );
      expect(c.routingLineOf(), e.routingLineOf());
      expect(c.routingLineOf(),
          '[tcp] final ⇒ vpn-1 : ✨auto → spotify.com');
    });

    test('compact — без [net]-префикса (для ряда)', () {
      final c = conn(domain: 'x.com', chains: ['node-fi', 'vpn-1']);
      final e = ev(domain: 'x.com', outboundChain: ['node-fi', 'vpn-1']);
      expect(c.routingLineOf(compact: true), e.routingLineOf(compact: true));
      expect(c.routingLineOf(compact: true),
          'final ⇒ vpn-1 : node-fi → x.com');
    });

    test('явное правило + detour (WARP)', () {
      final c = conn(
        domain: 'yt.com',
        rule: 'youtube',
        chains: ['node-de', 'vpn-2'],
        detours: ['WARP'],
      );
      final e = ev(
        domain: 'yt.com',
        rule: 'youtube',
        outboundChain: ['node-de', 'vpn-2'],
        detourChain: ['WARP'],
      );
      expect(c.routingLineOf(), e.routingLineOf());
      expect(c.routingLineOf(),
          '[tcp] youtube ⇒ vpn-2 : node-de → WARP → yt.com');
    });

    test('прямой outbound (без группы) — chains=[direct-out]', () {
      final c = conn(domain: 'google.com', chains: ['direct-out']);
      final e = ev(domain: 'google.com', outboundChain: ['direct-out']);
      expect(c.routingLineOf(), e.routingLineOf());
      expect(c.routingLineOf(), '[tcp] final : direct-out → google.com');
    });

    test('block — chains=[block], нет dest-домена', () {
      final c = conn(chains: ['block']);
      final e = ev(outboundChain: ['block']);
      expect(c.routingLineOf(), e.routingLineOf());
      expect(c.routingLineOf(), '[tcp] final : block');
    });

    test('пустой rule → final; chains[0]=node; selectors reversed', () {
      // chains [node, urltest, selector] → selectors сверху-вниз = [urltest, selector].reversed
      final c = conn(
        domain: 'a.b',
        chains: ['node-x', 'urltest-1', 'sel-1'],
      );
      final e = ev(
        domain: 'a.b',
        outboundChain: ['node-x', 'urltest-1', 'sel-1'],
      );
      expect(c.routingLineOf(), e.routingLineOf());
      expect(c.routingLineOf(),
          '[tcp] final ⇒ sel-1 ⇒ urltest-1 : node-x → a.b');
    });

    test('domain пуст → host из destination', () {
      final c = conn(destination: '1.2.3.4:443', chains: ['direct-out']);
      expect(c.routingLineOf(), '[tcp] final : direct-out → 1.2.3.4');
    });

    test('IPv6 destination — host в скобках сохраняется', () {
      final c = conn(destination: '[2001:db8::1]:443', chains: ['direct-out']);
      expect(c.routingLineOf(), '[tcp] final : direct-out → [2001:db8::1]');
    });

    test('ruleLabel override (резолвленное имя правила)', () {
      final c = conn(
        domain: 'x.com',
        rule: 'rule_42',
        chains: ['node', 'vpn-1'],
      );
      expect(c.routingLineOf(compact: true, ruleLabel: 'My YouTube Rule'),
          'My YouTube Rule ⇒ vpn-1 : node → x.com');
      // Пустой ruleLabel → берётся сырой rule.
      expect(c.routingLineOf(compact: true, ruleLabel: ''),
          'rule_42 ⇒ vpn-1 : node → x.com');
    });
  });
}
