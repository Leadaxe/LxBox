import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/screens/connection_detail/detail_data.dart';
import 'package:lxbox/services/traffic_profiler.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §662 — одна карточка для Conns и профайлера: адаптеры на одних данных
/// дают одинаковые общие поля.
void main() {
  const conn = CcConnection(
    id: 'c1',
    network: 'tcp',
    domain: 'example.com',
    destination: '93.184.216.34:443',
    source: '192.168.1.7:51514',
    inbound: 'wg-in',
    inboundType: 'wireguard',
    rule: 'final',
    uplink: 10,
    downlink: 20,
    outbound: 'node-a',
    outboundType: 'vless',
    protocol: 'tls',
    chains: ['node-a', 'auto'],
    detours: ['WARP'],
    packageName: 'org.example.app',
    processPath: 'org.example.app',
    createdAt: 1760000000000,
    closedAt: 0,
  );

  final event = TrafficEvent(
    ts: DateTime.fromMillisecondsSinceEpoch(1760000000000),
    kind: TrafficEventKind.tcpOpen,
    domain: 'example.com',
    ip: '93.184.216.34',
    port: 443,
    outboundChain: const ['node-a', 'auto'],
    detourChain: const ['WARP'],
    outboundType: 'vless',
    upBytes: 10,
    downBytes: 20,
    connId: 'c1',
    process: 'org.example.app',
    network: 'tcp',
    rule: 'final',
    source: '192.168.1.7:51514',
    inbound: 'wg-in',
    inboundType: 'wireguard',
    protocol: 'tls',
  );

  test('common fields match between Conns and profiler', () {
    final a = ConnectionDetailData.fromConnection(conn, closed: false);
    final b = ConnectionDetailData.fromEvent(event);
    for (final (name, x, y) in [
      ('title', a.title, b.title),
      ('package', a.package, b.package),
      ('processPath', a.processPath, b.processPath),
      ('source', a.source, b.source),
      ('inbound', a.inbound, b.inbound),
      ('inboundType', a.inboundType, b.inboundType),
      ('host', a.host, b.host),
      ('address', a.address, b.address),
      ('port', a.port, b.port),
      ('network', a.network, b.network),
      ('protocol', a.protocol, b.protocol),
      ('rule', a.rule, b.rule),
      ('outbound', a.outbound, b.outbound),
      ('outboundType', a.outboundType, b.outboundType),
      ('id', a.id, b.id),
      ('badge', a.badgeLabel, b.badgeLabel),
    ]) {
      expect(x, y, reason: name);
    }
    expect(a.chain, b.chain);
    expect(a.detour, b.detour);
    expect(a.upBytes, b.upBytes);
    expect(a.downBytes, b.downBytes);
    expect(a.title, 'example.com:443');
    expect(a.processPath, '', reason: 'path equal to package is not repeated');
  });

  test('closed connection: badge TCP· in outline, no closed word', () {
    final d = ConnectionDetailData.fromConnection(
      const CcConnection(
        id: 'c2',
        network: 'udp',
        domain: '',
        destination: '1.1.1.1:53',
        rule: '',
        uplink: 0,
        downlink: 0,
        createdAt: 1760000000000,
        closedAt: 1760000005000,
      ),
      closed: true,
    );
    expect(d.badgeLabel, 'UDP·');
    expect(d.badgeTone, DetailBadgeTone.outline);
    expect(d.title, '1.1.1.1:53');
    expect(d.duration, const Duration(seconds: 5));
    expect(d.closed, isTrue);
  });

  test('profiler close event is closed: TCP· + caption', () {
    final d = ConnectionDetailData.fromEvent(TrafficEvent(
      ts: DateTime(2026),
      kind: TrafficEventKind.tcpClose,
      ip: '1.1.1.1',
      port: 443,
    ));
    expect(d.badgeLabel, 'TCP·');
    expect(d.closed, isTrue);
  });

  test('event with process path: no package, path shown as Process', () {
    final d = ConnectionDetailData.fromEvent(TrafficEvent(
      ts: DateTime(2026),
      kind: TrafficEventKind.dnsResolve,
      domain: 'example.com',
      process: '/system/bin/netd',
    ));
    expect(d.package, '');
    expect(d.processPath, '/system/bin/netd');
    expect(d.badgeLabel, 'DNS');
    expect(d.closed, isFalse);
    expect(d.kind, 'dnsResolve');
    expect(d.title, 'example.com');
  });
}
