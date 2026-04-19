import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/parser/json_parsers.dart';

void main() {
  group('parseSingboxEntry', () {
    test('vless outbound fixture', () {
      final j = jsonDecode(
        File('test/fixtures/json/singbox_vless_outbound.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final spec = parseSingboxEntry(j);
      expect(spec, isA<VlessSpec>());
      final v = spec! as VlessSpec;
      expect(v.uuid, '11111111-2222-3333-4444-555555555555');
      expect(v.flow, 'xtls-rprx-vision');
      expect(v.tls.reality?.publicKey, isNotEmpty);
    });

    test('wireguard endpoint fixture', () {
      final j = jsonDecode(
        File('test/fixtures/json/singbox_wg_endpoint.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final spec = parseSingboxEntry(j);
      expect(spec, isA<WireguardSpec>());
      final wg = spec! as WireguardSpec;
      expect(wg.peers, hasLength(1));
      expect(wg.mtu, 1420);
    });

    test('unknown type → null', () {
      expect(parseSingboxEntry({'type': 'bogus'}), isNull);
    });
  });

  group('parseXrayOutbound', () {
    test('reality array fixture', () {
      final j = jsonDecode(
        File('test/fixtures/json/xray_array_reality.json').readAsStringSync(),
      ) as List;
      final spec = parseXrayOutbound(j.first as Map<String, dynamic>);
      expect(spec, isA<VlessSpec>());
      final v = spec! as VlessSpec;
      expect(v.uuid, '11111111-2222-3333-4444-555555555555');
      expect(v.tls.reality?.publicKey, isNotEmpty);
    });
  });
}
