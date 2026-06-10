import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/subscriptions_screen/clipboard_analysis.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

// §110 — Amnezia vpn://-ссылки. Энкодер-хелпер повторяет формат
// qCompress: 4 байта big-endian длины + zlib-поток, base64url без padding.

List<int> _qCompress(List<int> data) => [
      (data.length >> 24) & 0xff,
      (data.length >> 16) & 0xff,
      (data.length >> 8) & 0xff,
      data.length & 0xff,
      ...zlib.encode(data),
    ];

String makeLink(Object config, {bool compressed = true, bool pad = false}) {
  final raw = utf8.encode(jsonEncode(config));
  final payload = compressed ? _qCompress(raw) : raw;
  var b64 = base64Url.encode(payload);
  if (!pad) b64 = b64.replaceAll('=', '');
  return 'vpn://$b64';
}

const _awgIni = r'''
[Interface]
Address = 10.8.1.2/32
DNS = $PRIMARY_DNS, $SECONDARY_DNS
PrivateKey = cGFyc2VyLXRlc3QtcHJpdmF0ZS1rZXktYWJjZGVmZ2g=
Jc = 4
Jmin = 40
Jmax = 70
S1 = 116
S2 = 61
H1 = 1239197098
H2 = 1929999858
H3 = 1842910958
H4 = 1234567891

[Peer]
PublicKey = cGFyc2VyLXRlc3QtcHVibGljLWtleS1hYmNkZWZnaA=
PresharedKey = cGFyc2VyLXRlc3QtcHNrLWtleS1hYmNkZWZnaGlqaw=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.10:43210
PersistentKeepalive = 25
''';

const _plainWgIni = '''
[Interface]
Address = 10.0.0.2/32
PrivateKey = cGFyc2VyLXRlc3QtcHJpdmF0ZS1rZXktYWJjZGVmZ2g=

[Peer]
PublicKey = cGFyc2VyLXRlc3QtcHVibGljLWtleS1hYmNkZWZnaA=
Endpoint = 198.51.100.7:51820
''';

Map<String, dynamic> _container(String proto, String ini,
    {bool lastConfigAsMap = false}) {
  final lastConfig = {'config': ini, 'mtu': '1280', 'port': '43210'};
  return {
    'container': proto == 'awg' ? 'amnezia-awg' : 'amnezia-wireguard',
    proto: {
      'last_config': lastConfigAsMap ? lastConfig : jsonEncode(lastConfig),
      'port': '43210',
      'transport_proto': 'udp',
    },
  };
}

Map<String, dynamic> _export(List<Map<String, dynamic>> containers) => {
      'containers': containers,
      'defaultContainer': 'amnezia-awg',
      'description': 'Test Server',
      'dns1': '1.1.1.1',
      'dns2': '1.0.0.1',
      'hostName': '203.0.113.10',
    };

void main() {
  group('decode vpn:// (§110)', () {
    test('AWG-контейнер → AmneziaConfig → AWG-нода end-to-end', () {
      final link = makeLink(_export([_container('awg', _awgIni)]));
      final decoded = decode(link);
      expect(decoded, isA<AmneziaConfig>());

      final nodes = parseAll(decoded);
      expect(nodes, hasLength(1));
      final spec = nodes.single as WireguardSpec;
      expect(spec.server, '203.0.113.10');
      expect(spec.port, 43210);
      expect(spec.awg, isNotNull);
      expect(spec.awg!.fields['jc'], 4);
      expect(spec.awg!.fields['jmax'], 70);
      expect(spec.awg!.fields['h1'], 1239197098);
      expect(spec.mtu, 1280); // §097 AWG-кламп при отсутствии явного MTU
      expect(spec.peers.single.endpointHost, '203.0.113.10');
    });

    test('DNS-плейсхолдеры подставлены из dns1/dns2 в rawIni', () {
      final link = makeLink(_export([_container('awg', _awgIni)]));
      final spec = parseAll(decode(link)).single as WireguardSpec;
      expect(spec.rawIni, contains('1.1.1.1'));
      expect(spec.rawIni, contains('1.0.0.1'));
      expect(spec.rawIni, isNot(contains(r'$PRIMARY_DNS')));
    });

    test('wireguard-контейнер (plain WG) → нода без awg', () {
      final link = makeLink(_export([_container('wireguard', _plainWgIni)]));
      final spec = parseAll(decode(link)).single as WireguardSpec;
      expect(spec.awg, isNull);
      expect(spec.server, '198.51.100.7');
    });

    test('last_config как Map (не JSON-строка) — тоже принимается', () {
      final link = makeLink(
          _export([_container('awg', _awgIni, lastConfigAsMap: true)]));
      expect(parseAll(decode(link)), hasLength(1));
    });

    test('несжатый payload (fallback importController) → парсится', () {
      final link =
          makeLink(_export([_container('awg', _awgIni)]), compressed: false);
      expect(parseAll(decode(link)), hasLength(1));
    });

    test('base64 с padding → терпим', () {
      final link =
          makeLink(_export([_container('awg', _awgIni)]), pad: true);
      expect(parseAll(decode(link)), hasLength(1));
    });

    test('два контейнера (awg + wireguard) → 2 ноды, один decode', () {
      final link = makeLink(_export([
        _container('awg', _awgIni),
        _container('wireguard', _plainWgIni),
      ]));
      final decoded = decode(link) as AmneziaConfig;
      expect(decoded.iniTexts, hasLength(2));
      expect(parseAll(decoded), hasLength(2));
    });

    test('мусор после vpn:// → DecodeFailure', () {
      expect(decode('vpn://%%%не-base64%%%'), isA<DecodeFailure>());
    });

    test('валидный base64, но не JSON → DecodeFailure', () {
      final link = 'vpn://${base64Url.encode(utf8.encode('hello world, not json'))}';
      expect(decode(link), isA<DecodeFailure>());
    });

    test('контейнеры без WG/AWG (xray-only) → DecodeFailure', () {
      final link = makeLink(_export([
        {
          'container': 'amnezia-xray',
          'xray': {'last_config': '{}', 'port': '443'},
        }
      ]));
      final decoded = decode(link);
      expect(decoded, isA<DecodeFailure>());
      expect((decoded as DecodeFailure).reason, contains('containers'));
    });

    test('слишком длинная ссылка → DecodeFailure (анти-бомба)', () {
      final link = 'vpn://${'A' * 70000}';
      expect(decode(link), isA<DecodeFailure>());
    });
  });

  group('персист UserServer с rawBody = vpn:// (§110)', () {
    test('toJson/fromJson round-trip восстанавливает ноды из ссылки', () {
      final link = makeLink(_export([_container('awg', _awgIni)]));
      final server = UserServer(
        id: 'test-id',
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        rawBody: link,
        nodes: parseAll(decode(link)),
      );
      final restored = UserServer.fromJson(server.toJson());
      expect(restored.nodes, hasLength(1));
      final spec = restored.nodes.single as WireguardSpec;
      expect(spec.awg, isNotNull);
      expect(spec.server, '203.0.113.10');
    });
  });

  group('analyzeClipboard vpn:// (§110)', () {
    test('валидная ссылка → карточка amnezia_vpn с endpoint', () {
      final link = makeLink(_export([_container('awg', _awgIni)]));
      final a = analyzeClipboard(link);
      expect(a.type, 'amnezia_vpn');
      expect(a.title, 'Amnezia VPN config');
      expect(a.subtitle, contains('203.0.113.10:43210'));
    });

    test('два контейнера → суффикс × 2', () {
      final link = makeLink(_export([
        _container('awg', _awgIni),
        _container('wireguard', _plainWgIni),
      ]));
      expect(analyzeClipboard(link).subtitle, contains('× 2'));
    });

    test('битая ссылка → unknown (стандартный диалог)', () {
      expect(analyzeClipboard('vpn://!!!').type, 'unknown');
    });
  });
}
