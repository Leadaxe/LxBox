import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/json_parsers.dart';

void main() {
  group('parseSingboxEntry', () {
    test('§115: raw sing-box JSON flow=vision + transport → emit гасит flow',
        () {
      // parseSingboxEntry читает flow напрямую (spec.flow=vision), но
      // универсальный net на эмиссии (§115) убирает flow при транспорте —
      // покрывает путь, который парсерные guard'ы URI/Xray не трогают.
      final spec = parseSingboxEntry({
        'type': 'vless',
        'tag': 't',
        'server': 'h.example',
        'server_port': 443,
        'uuid': '11111111-2222-3333-4444-555555555555',
        'flow': 'xtls-rprx-vision',
        'tls': {'enabled': true, 'server_name': 'w.example'},
        'transport': {'type': 'ws', 'path': '/x'},
      }) as VlessSpec;
      final emitted = spec.emit(TemplateVars.empty).map;
      expect(emitted['flow'], isNull, reason: 'flow+transport невалидно');
      expect(emitted['transport'], isNotNull);
    });

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

    test('§115: Xray REALITY+tcp без flow → flow ПУСТОЙ (не навязываем)', () {
      final spec = parseXrayOutbound({
        'outbounds': [
          {
            'tag': 'proxy',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'h.example',
                  'port': 443,
                  'users': [
                    {'id': '11111111-2222-3333-4444-555555555555'}
                  ],
                }
              ],
            },
            'streamSettings': {
              'network': 'tcp',
              'security': 'reality',
              'realitySettings': {'publicKey': 'PK', 'shortId': 'abcd'},
            },
          }
        ],
      }) as VlessSpec;
      expect(spec.flow, '', reason: 'REALITY+tcp без flow → не vision');
      expect(spec.tls.reality?.publicKey, isNotEmpty);
    });
  });
}
