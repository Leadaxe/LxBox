import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import 'engine_test_setup.dart';

void main() {
  setUpAll(loadEngineSections);

  group('§484 — required маппера даёт field_missing, а не молчаливый null', () {
    test('vless без address — узла нет, причина field_missing', () {
      final dropped = <NodeWarning>[];
      final nodes = parseAll(
        decode('vless://11111111-2222-3333-4444-555555555555@:443'),
        dropped: dropped,
      );
      expect(nodes, isEmpty);
      expect(dropped, hasLength(1));
      final w = dropped.single as RegistryWarning;
      expect(w.code, 'field_missing');
      expect(w.path, 'server');
      expect(w.params['field'], 'server');
    });

    test('xray vless без port — узла нет, field_missing с desc_en записи', () {
      final dropped = <NodeWarning>[];
      final nodes = parseAll(
        decode(jsonEncode({
          'remarks': 'no-port',
          'outbounds': [
            {
              'tag': 'proxy',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': 'h.example',
                    'users': [
                      {'id': '11111111-2222-3333-4444-555555555555'},
                    ],
                  },
                ],
              },
              'streamSettings': {'network': 'tcp', 'security': 'none'},
            },
          ],
        })),
        dropped: dropped,
      );
      expect(nodes, isEmpty);
      expect(dropped, hasLength(1));
      final w = dropped.single as RegistryWarning;
      expect(w.code, 'field_missing');
      expect(w.path, 'server_port');
      expect(w.params['field'], 'server port is missing or out of range');
      expect(w.ownerTag, 'proxy');
    });

    test('[Peer] без Endpoint — узла нет, field_missing на пути пира', () {
      const priv = 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=';
      const pub = 'AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=';
      const text = '[Interface]\n'
          'PrivateKey = $priv\n'
          'Address = 10.0.0.2/32\n'
          '\n'
          '[Peer]\n'
          'PublicKey = $pub\n'
          'AllowedIPs = 0.0.0.0/0\n';

      final dropped = <NodeWarning>[];
      final nodes = parseAll(decode(text), dropped: dropped);
      expect(nodes, isEmpty);
      expect(dropped, hasLength(1));
      final w = dropped.single as RegistryWarning;
      expect(w.code, 'field_missing');
      expect(w.path, 'peers[].address');
      expect(w.params['field'], 'peers[].address');
    });
  });
}
