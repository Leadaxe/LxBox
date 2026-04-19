import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/ini_parser.dart';

void main() {
  group('parseWireguardIni', () {
    test('fixture ini_basic.conf → WireguardSpec with peer', () {
      final text = File('test/fixtures/wireguard/ini_basic.conf').readAsStringSync();
      final spec = parseWireguardIni(text);
      expect(spec, isNotNull);
      expect(spec!.server, 'example-3.com');
      expect(spec.port, 51820);
      expect(spec.peers, hasLength(1));
      expect(spec.peers.first.publicKey, contains('bbbbbbb'));
      expect(spec.peers.first.preSharedKey, contains('eeeeeee'));
      expect(spec.peers.first.persistentKeepalive, 25);
      expect(spec.mtu, 1420);
      expect(spec.rawIni, contains('[Interface]'));
    });

    test('missing PrivateKey → null', () {
      const ini = '[Interface]\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = p\nEndpoint = h:51820\n';
      expect(parseWireguardIni(ini), isNull);
    });

    test('IPv6 endpoint [::1]:51820 parses', () {
      const ini = '[Interface]\nPrivateKey = pk\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = pubk\nEndpoint = [::1]:51820\n';
      final spec = parseWireguardIni(ini);
      expect(spec, isNotNull);
      expect(spec!.server, '::1');
      expect(spec.port, 51820);
    });
  });
}
