import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §130 — MasqueSpec emit (Outbound-схема ядра) + URI round-trip.
void main() {
  MasqueSpec spec() => MasqueSpec(
        id: 'id1',
        tag: '🔥🎭 WARP (MASQUE)',
        label: '🔥🎭 WARP (MASQUE)',
        server: '162.159.198.1',
        port: 443,
        rawUri: '',
        privateKeyDer: 'PRIVDER==',
        publicKeyDer: 'PUBDER==',
        localAddresses: ['172.16.0.2/32', '2606:4700:110::2/128'],
        network: 'h3',
        mtu: 1280,
        idleTimeout: '10m',
        keepAlive: '45s',
      );

  test('emitMasque даёт Outbound с плоской схемой ядра', () {
    final entry = spec().emit(TemplateVars.empty);
    expect(entry, isA<Outbound>()); // НЕ Endpoint!
    final m = entry.map;
    expect(m['type'], 'masque');
    expect(m['server'], '162.159.198.1');
    expect(m['server_port'], 443);
    expect(m['profile'], 'cloudflare');
    expect(m['network'], 'h3');
    expect(m['private_key'], 'PRIVDER==');
    expect(m['public_key'], 'PUBDER==');
    expect(m['ip'], '172.16.0.2/32'); // v4 из localAddresses
    expect(m['ipv6'], '2606:4700:110::2/128'); // v6 из localAddresses
    expect(m['mtu'], 1280);
    expect(m['idle_timeout'], '10m');
    expect(m['keep_alive_period'], '45s'); // ключ ядра, не 'keep_alive'
    // нет полей WireGuard
    expect(m.containsKey('peers'), isFalse);
    expect(m.containsKey('address'), isFalse);
    expect(m.containsKey('certificate'), isFalse);
  });

  test('URI round-trip: spec.toUri() → parseMasqueUri ≈ spec', () {
    final s = spec();
    final uri = s.toUri();
    expect(uri, startsWith('masque://'));
    final parsed = parseMasqueUri(uri);
    expect(parsed, isNotNull);
    expect(parsed!.privateKeyDer, s.privateKeyDer);
    expect(parsed.publicKeyDer, s.publicKeyDer);
    expect(parsed.server, s.server);
    expect(parsed.port, s.port);
    expect(parsed.network, s.network);
    expect(parsed.localAddresses, containsAll(s.localAddresses));
    expect(parsed.idleTimeout, '10m');
    expect(parsed.keepAlive, '45s');
  });

  test('parseUri диспетчеризует masque://', () {
    final parsed = parseUri(spec().toUri());
    expect(parsed, isA<MasqueSpec>());
  });
}
