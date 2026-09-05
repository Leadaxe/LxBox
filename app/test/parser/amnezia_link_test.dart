import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/template_vars.dart';
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
PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=
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
PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=
PresharedKey = ccccccccccccccccccccccccccccccccccccccccccA=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.10:43210
PersistentKeepalive = 25
''';

const _plainWgIni = '''
[Interface]
Address = 10.0.0.2/32
PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=

[Peer]
PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=
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

    test('ranged magic headers (§112) доезжают через vpn://', () {
      final ranged = _awgIni.replaceFirst(
          'H1 = 1239197098', 'H1 = 43613244-384550127');
      final link = makeLink(_export([_container('awg', ranged)]));
      final spec = parseAll(decode(link)).single as WireguardSpec;
      expect(spec.awg!.fields['h1'], '43613244-384550127');
      expect(spec.awg!.fields['h2'], 1929999858); // одиночный остался int
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

  // §421 — экспорт AWG 3.1: контейнер amnezia-awg2, protocol_version "3.1",
  // MTU лежит в last_config.mtu (не в [Interface]), DNS через плейсхолдеры.
  // Ключи синтетические.
  group('§421 — AWG 3.1 экспорт (amnezia-awg2)', () {
    const hk = 'Bw4VHCMqMTg/Rk1UW2JpcHd+hYyTmqGor7a9xMvS2eA=';
    const awg3Ini = r'''
[Interface]
Address = 10.8.1.7/32
DNS = $PRIMARY_DNS, $SECONDARY_DNS
PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=
Jc = 4
Jmin = 10
Jmax = 50
S1 = 55
S2 = 42
S3 = 40
S4 = 12
H1 = 1
H2 = 2
H3 = 3
H4 = 4
HeaderProtectionKey = Bw4VHCMqMTg/Rk1UW2JpcHd+hYyTmqGor7a9xMvS2eA=
ContentPaddingAddition = 10-100
RekeyAfterTime = 100-120
RekeyTimeout = 3-7
RejectAfterTime = 150-180
KeepaliveTimeout = 5-15
MaxHandshakeAttempts = 15-20
RandomTrailers = on
DisableCookies = on

[Peer]
PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=
PresharedKey = ccccccccccccccccccccccccccccccccccccccccccA=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.9:30565
PersistentKeepalive = 25-35
''';
    Map<String, dynamic> awg3Container({String? mtu = '1376'}) => {
          'container': 'amnezia-awg2',
          'awg': {
            'last_config': jsonEncode({
              'config': awg3Ini,
              'mtu': ?mtu,
              'port': '30565',
              'protocol_version': '3.1',
            }),
            'port': '30565',
            'protocol_version': '3.1',
            'transport_proto': 'udp',
          },
        };
    Map<String, dynamic> export3(Map<String, dynamic> c) => {
          'containers': [c],
          'defaultContainer': 'amnezia-awg2',
          'description': 'AWG3 Node',
          'dns1': '172.29.172.254',
          'dns2': '1.0.0.1',
          'hostName': '203.0.113.9',
        };

    test('end-to-end: mtu 1376 из last_config, keepalive "25-35", тайминги, '
        'булевы, DNS без плейсхолдеров', () {
      final link = makeLink(export3(awg3Container()));
      final spec = parseAll(decode(link)).single as WireguardSpec;
      final f = spec.awg!.fields;
      expect(f['header_protection_key'], hk);
      expect(f['content_padding_addition'], '10-100');
      expect(f['max_handshake_attempts'], '15-20');
      expect(f['random_trailers'], true);
      expect(f['disable_cookies'], true);
      expect(f['h1'], 1);
      expect(spec.mtu, 1376);
      expect(spec.peers.single.persistentKeepalive, '25-35');
      expect(spec.rawIni, contains('MTU = 1376'));
      expect(spec.rawIni, contains('172.29.172.254'));
      expect(spec.rawIni, isNot(contains(r'$PRIMARY_DNS')));
      final map = spec.emit(TemplateVars.empty).map;
      expect(map['mtu'], 1376);
      expect(map['reject_after_time'], '150-180');
    });

    test('явный MTU в [Interface] приоритетнее last_config.mtu', () {
      final c = awg3Container();
      final lc = jsonDecode(c['awg']['last_config'] as String) as Map;
      lc['config'] = (lc['config'] as String)
          .replaceFirst('[Interface]\n', '[Interface]\nMTU = 1300\n');
      c['awg']['last_config'] = jsonEncode(lc);
      final spec = parseAll(decode(makeLink(export3(c)))).single as WireguardSpec;
      expect(spec.mtu, 1300);
    });

    test('без last_config.mtu и без MTU — поле не задано (без клампа)', () {
      final spec = parseAll(decode(makeLink(export3(awg3Container(mtu: null)))))
          .single as WireguardSpec;
      expect(spec.mtu, isNull);
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
