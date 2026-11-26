// §764 — разбор карты `tunnel` статуса openconnect.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/vpn/cc_openconnect.dart';

void main() {
  test('no tunnel key → tunnel is null', () {
    final s = CcOpenConnectStatus.fromMap({'tag': 'oc', 'state': 'connecting'});
    expect(s.tunnel, isNull);
  });

  test('old tunnel map without lists → empty lists', () {
    final s = CcOpenConnectStatus.fromMap({
      'tag': 'oc',
      'state': 'connected',
      'tunnel': {
        'server': 'gw.example.com:443',
        'flavor': 'fortinet',
        'transport': 'DTLS',
        'mtu': 1350,
        'connected_since': 1764160800,
      },
    });
    final t = s.tunnel!;
    expect(t.server, 'gw.example.com:443');
    expect(t.flavor, 'fortinet');
    expect(t.transport, 'DTLS');
    expect(t.mtu, 1350);
    expect(t.connectedSince, 1764160800);
    expect(t.ipv4, isEmpty);
    expect(t.ipv6, isEmpty);
    expect(t.dns, isEmpty);
  });

  test('full tunnel map → lists and numbers', () {
    final snap = CcOpenConnectSnapshot.fromObject({
      'endpoints': [
        {
          'tag': 'oc',
          'state': 'connected',
          'tunnel': {
            'server': 'gw',
            'flavor': 'anyconnect',
            'transport': 'TLS',
            // Натив отдаёт Long/Int — в Dart может прийти любое num.
            'mtu': 1400.0,
            'connected_since': 1764160800,
            'ipv4': ['10.0.0.5/32'],
            'ipv6': ['fd00::5/128'],
            'dns': ['10.0.0.1', '10.0.0.2'],
          },
        },
      ],
    });
    final t = snap.endpoints['oc']!.tunnel!;
    expect(t.mtu, 1400);
    expect(t.ipv4, ['10.0.0.5/32']);
    expect(t.ipv6, ['fd00::5/128']);
    expect(t.dns, ['10.0.0.1', '10.0.0.2']);
  });

  test('garbage values → defaults', () {
    final t = CcOpenConnectTunnel.fromMap({'mtu': 'x', 'ipv4': 'nope'});
    expect(t.mtu, 0);
    expect(t.connectedSince, 0);
    expect(t.ipv4, isEmpty);
  });
}
