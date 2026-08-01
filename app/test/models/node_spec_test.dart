import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/tls_spec.dart';
import 'package:lxbox/models/transport_spec.dart';

void main() {
  group('NodeSpec construction + exhaustive switch', () {
    test('VlessSpec with Reality TLS + TCP', () {
      final spec = VlessSpec(
        id: 'v1',
        tag: 'vless-1',
        label: 'VLESS Reality',
        server: 'example-1.com',
        port: 443,
        rawUri: 'vless://...',
        uuid: '11111111-2222-3333-4444-555555555555',
        flow: 'xtls-rprx-vision',
        tls: const TlsSpec(
          enabled: true,
          serverName: 'www.example.com',
          fingerprint: 'chrome',
          reality: RealitySpec(publicKey: 'pk', shortId: 'sid'),
        ),
      );
      expect(spec.protocol, 'vless');
      expect(spec.tls.reality?.publicKey, 'pk');
      expect(spec.warnings, isEmpty);
    });

    test('warnings mutable after construction (§2.4 decision)', () {
      final spec = VlessSpec(
        id: 'v1',
        tag: 'vless-1',
        label: 'l',
        server: 'h',
        port: 443,
        rawUri: 'u',
        uuid: 'u',
      );
      spec.warnings.add(const InsecureTlsWarning());
      expect(spec.warnings, hasLength(1));
      expect(spec.warnings.single, isA<InsecureTlsWarning>());
    });

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
        rawUri: 'wireguard://...',
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

    test('exhaustive switch compiles for all NodeSpec variants', () {
      final specs = <NodeSpec>[
        VlessSpec(
            id: '1', tag: 't', label: 'l', server: 's', port: 1, rawUri: 'u', uuid: 'u'),
        VmessSpec(
            id: '2', tag: 't', label: 'l', server: 's', port: 1, rawUri: 'u', uuid: 'u'),
        TrojanSpec(
            id: '3', tag: 't', label: 'l', server: 's', port: 1, rawUri: 'u', password: 'p'),
        ShadowsocksSpec(
            id: '4', tag: 't', label: 'l', server: 's', port: 1, rawUri: 'u',
            method: 'aes-256-gcm', password: 'p'),
        Hysteria2Spec(
            id: '5', tag: 't', label: 'l', server: 's', port: 1, rawUri: 'u', password: 'p'),
        TuicSpec(
            id: '6', tag: 't', label: 'l', server: 's', port: 1, rawUri: 'u',
            uuid: 'u', password: 'p'),
        SshSpec(
            id: '7', tag: 't', label: 'l', server: 's', port: 22, rawUri: 'u', user: 'root'),
        SocksSpec(
            id: '8', tag: 't', label: 'l', server: 's', port: 1080, rawUri: 'u'),
        HttpSpec(
            id: '12', tag: 't', label: 'l', server: 's', port: 8080, rawUri: 'u'),
        WireguardSpec(
            id: '9', tag: 't', label: 'l', server: 's', port: 51820, rawUri: 'u',
            privateKey: 'pk', localAddresses: const [], peers: const []),
        NaiveSpec(
            id: '10', tag: 't', label: 'l', server: 's', port: 443, rawUri: 'u',
            password: 'p'),
        MasqueSpec(
            id: '11', tag: 't', label: 'l', server: 's', port: 443, rawUri: 'u',
            privateKeyDer: 'pk', publicKeyDer: 'pub',
            localAddresses: const ['172.16.0.2/32']),
        AnyTlsSpec(
            id: '13', tag: 't', label: 'l', server: 's', port: 443, rawUri: 'u',
            password: 'p'),
        // §322 — узел-группа: без server/port, отсюда отдельный конструктор.
        AutoSelectSpec(
            id: '14', tag: 't', label: 'l'),
      ];

      for (final s in specs) {
        final p = switch (s) {
          VlessSpec() => 'vless',
          VmessSpec() => 'vmess',
          TrojanSpec() => 'trojan',
          ShadowsocksSpec() => 'shadowsocks',
          Hysteria2Spec() => 'hysteria2',
          TuicSpec() => 'tuic',
          SshSpec() => 'ssh',
          SocksSpec() => 'socks',
          HttpSpec() => 'http',
          WireguardSpec() => 'wireguard',
          NaiveSpec() => 'naive',
          MasqueSpec() => 'masque',
          AnyTlsSpec() => 'anytls',
          AutoSelectSpec() => 'urltest',
        };
        expect(p, s.protocol);
      }
    });
  });
}
