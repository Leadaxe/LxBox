import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/uri_parsers/wireguard_parser.dart';
import 'package:lxbox/services/parser/uri_utils.dart';

/// §025 — WireGuard `reserved` (Cloudflare WARP client_id): parse, emit, и
/// round-trip URI ⇄ spec ⇄ endpoint-JSON.
void main() {
  group('parseReserved', () {
    test('десятичный b0,b1,b2 → 3 байта', () {
      expect(parseReserved('1,2,3'), [1, 2, 3]);
      expect(parseReserved(' 10, 20, 30 '), [10, 20, 30]);
    });

    test('base64 client_id (3 байта) → байты', () {
      final b64 = base64.encode([42, 7, 200]);
      expect(parseReserved(b64), [42, 7, 200]);
    });

    test('не 3 значения / вне 0..255 / мусор → null', () {
      expect(parseReserved('1,2'), isNull);
      expect(parseReserved('1,2,3,4'), isNull);
      expect(parseReserved('1,2,300'), isNull);
      expect(parseReserved('a,b,c'), isNull);
      expect(parseReserved(''), isNull);
      expect(parseReserved(base64.encode([1, 2, 3, 4])), isNull); // 4 байта
    });
  });

  group('parseWireguardUri — reserved', () {
    test('reserved=b0,b1,b2 попадает в peer', () {
      final spec = parseWireguardUri(
          'wireguard://PRIV=@engage.cloudflareclient.com:2408'
          '?publickey=PUB=&address=172.16.0.2/32&reserved=12,34,56#WARP');
      expect(spec, isNotNull);
      expect(spec!.peers.first.reserved, [12, 34, 56]);
    });

    test('без reserved → null в peer (обычный WG не ломается)', () {
      final spec = parseWireguardUri(
          'wireguard://PRIV=@h.example:51820?publickey=PUB=&address=10.0.0.2/32');
      expect(spec!.peers.first.reserved, isNull);
    });

    test('client_id (base64) как alias reserved', () {
      final b64 = base64.encode([9, 9, 9]);
      final spec = parseWireguardUri(
          'wireguard://PRIV=@h.example:2408?publickey=PUB=&address=1.1.1.1/32'
          '&client_id=$b64');
      expect(spec!.peers.first.reserved, [9, 9, 9]);
    });
  });

  group('emitWireguard — reserved', () {
    test('reserved эмитится per-peer в endpoint-JSON', () {
      final spec = WireguardSpec(
        id: 'id',
        tag: 'WARP',
        label: 'WARP',
        server: 'engage.cloudflareclient.com',
        port: 2408,
        rawUri: '',
        privateKey: 'PRIV=',
        localAddresses: ['172.16.0.2/32'],
        peers: [
          const WireguardPeer(
            publicKey: 'PUB=',
            endpointHost: 'engage.cloudflareclient.com',
            endpointPort: 2408,
            reserved: [12, 34, 56],
          ),
        ],
      );
      final endpoint = spec.emit(TemplateVars.empty);
      final peer = (endpoint.map['peers'] as List).first as Map;
      expect(peer['reserved'], [12, 34, 56]);
    });

    test('без reserved — ключа нет в JSON', () {
      final spec = WireguardSpec(
        id: 'id',
        tag: 'wg',
        label: 'wg',
        server: 'h.example',
        port: 51820,
        rawUri: '',
        privateKey: 'PRIV=',
        localAddresses: ['10.0.0.2/32'],
        peers: const [
          WireguardPeer(
            publicKey: 'PUB=',
            endpointHost: 'h.example',
            endpointPort: 51820,
          ),
        ],
      );
      final endpoint = spec.emit(TemplateVars.empty);
      final peer = (endpoint.map['peers'] as List).first as Map;
      expect(peer.containsKey('reserved'), isFalse);
    });
  });

  test('URI round-trip: parse → toUri → parse сохраняет reserved', () {
    const uri = 'wireguard://PRIV=@engage.cloudflareclient.com:2408'
        '?publickey=PUB=&address=172.16.0.2/32&reserved=12,34,56#WARP';
    final spec1 = parseWireguardUri(uri)!;
    final back = spec1.toUri();
    final spec2 = parseWireguardUri(back)!;
    expect(spec2.peers.first.reserved, [12, 34, 56]);
  });
}
