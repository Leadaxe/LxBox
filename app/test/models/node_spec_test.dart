import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/transport_spec.dart';

void main() {
  group('NodeSpec construction + exhaustive switch', () {
    test('§097 — XhttpTransport emits native xhttp (no fallback)', () {
      final (map, warnings) = const XhttpTransport(
        path: '/xh',
        host: 'h',
        mode: 'packet-up',
        xPaddingBytes: '100-1000',
        noGrpcHeader: true,
      ).toSingbox(TemplateVars.empty);
      expect(map['type'], 'xhttp');
      expect(map['path'], '/xh');
      expect(map['host'], 'h');
      expect(map['mode'], 'packet-up');
      expect(map['x_padding_bytes'], '100-1000');
      expect(map['no_grpc_header'], true);
      expect(warnings, isEmpty);
    });

    test('WireguardSpec.emit returns Endpoint (not Outbound)', () {
      final spec = WireguardSpec(
        id: 'w1',
        tag: 'wg-1',
        label: 'WG',
        server: 'example.com',
        port: 51820,
        rawSource: 'wireguard://...',
        privateKey: 'pk',
        localAddresses: const ['10.0.0.2/32'],
        peers: const [
          WireguardPeer(
            publicKey: 'peer-pk',
            endpointHost: 'example.com',
            endpointPort: 51820,
          ),
        ],
      );
      expect(spec.protocol, 'wireguard');
      final entry = spec.emit(TemplateVars.empty);
      expect(entry.map['type'], 'wireguard');
      expect(entry.map['peers'], isList);
    });
  });
}
