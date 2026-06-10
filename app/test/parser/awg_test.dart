import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/ini_parser.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §097 Phase 1 — AmneziaWG2 (AWG) сквозной проход: URI/JSON/INI → Awg → emit →
/// round-trip. По образцу singbox-launcher SPEC 073 (Фазы 1-4, 6).
void main() {
  const i1 = '<b 0x000100002112a442><r 12>';
  const i3 = '<r 24>';
  final fullUri = 'wireguard://PRIV@host.example.com:51821'
      '?publickey=PUB&address=10.0.0.2/32&allowedips=0.0.0.0/0,::/0'
      '&mtu=1408&keepalive=25'
      '&jc=10&jmin=50&jmax=100&s1=20&s2=20&s3=60&s4=60'
      '&h1=1234567890&h2=1234567891&h3=1234567892&h4=1234567893'
      '&i1=${Uri.encodeQueryComponent(i1)}'
      '&i3=${Uri.encodeQueryComponent(i3)}#awg-server';

  group('Фаза 1 — parse URI', () {
    test('все AWG-поля: числа int, i* регистр сохранён, i2/i4/i5 отсутствуют', () {
      final awg = parseWireguardUri(fullUri)!.awg!;
      expect(awg.fields['jc'], 10);
      expect(awg.fields['jc'], isA<int>());
      expect(awg.fields['jmax'], 100);
      expect(awg.fields['s4'], 60);
      expect(awg.fields['h1'], 1234567890);
      expect(awg.fields['i1'], i1);
      expect(awg.fields['i3'], i3);
      expect(awg.fields.containsKey('i2'), false);
      expect(awg.fields.containsKey('i4'), false);
    });

    test('обычный WG (без AWG) → spec.awg == null', () {
      final spec = parseWireguardUri(
          'wireguard://PRIV@h:51820?publickey=PUB&address=10.0.0.2/32')!;
      expect(spec.awg, isNull);
    });

    test('битое число (jc=abc) → поле пропущено, парс не падает', () {
      final spec = parseWireguardUri(
          'wireguard://P@h:51820?publickey=K&address=10.0.0.2/32&jc=abc&jmin=50')!;
      expect(spec.awg!.fields.containsKey('jc'), false);
      expect(spec.awg!.fields['jmin'], 50);
    });
  });

  group('Фаза 2 — awg:// scheme', () {
    test('awg:// → WireguardSpec, protocol wireguard, AWG на месте', () {
      final spec = parseUri(fullUri.replaceFirst('wireguard://', 'awg://'));
      expect(spec, isA<WireguardSpec>());
      spec as WireguardSpec;
      expect(spec.protocol, 'wireguard');
      expect(spec.awg!.fields['jc'], 10);
    });
  });

  group('Фаза 3 — emit (числа как JSON number)', () {
    test('endpoint root содержит AWG; jc — number, i1 — string', () {
      final spec = parseWireguardUri(fullUri)!;
      final map = spec.emit(TemplateVars.empty).map;
      expect(map['jc'], 10);
      expect(map['i1'], i1);
      final json = jsonEncode(map);
      expect(json.contains('"jc":10'), true, reason: 'number, не "10"');
      expect(json.contains('"jc":"10"'), false);
      // type-fidelity: re-decode → jc остаётся числом.
      final back = jsonDecode(json) as Map<String, dynamic>;
      expect(back['jc'], isA<num>());
      expect(back['i1'], isA<String>());
    });

    test('обычный WG emit без AWG-ключей', () {
      final spec = parseWireguardUri(
          'wireguard://P@h:51820?publickey=K&address=10.0.0.2/32')!;
      final map = spec.emit(TemplateVars.empty).map;
      expect(map.keys.any(Awg.numKeys.contains), false);
      expect(map.keys.any(Awg.strKeys.contains), false);
    });
  });

  group('Фаза 4 — round-trip share-URI', () {
    test('URI→spec→toUri→spec сохраняет AWG (включая регистр i*)', () {
      final s1 = parseWireguardUri(fullUri)!;
      final s2 = parseWireguardUri(s1.toUri())!;
      expect(s2.awg!.fields, s1.awg!.fields);
      expect(s2.awg!.fields['i1'], i1);
    });

    test('jc=0 (junk off) — явный ноль переживает round-trip', () {
      final s1 = parseWireguardUri(
          'wireguard://P@h:51820?publickey=K&address=10.0.0.2/32&jc=0')!;
      expect(s1.awg!.fields['jc'], 0);
      final s2 = parseWireguardUri(s1.toUri())!;
      expect(s2.awg!.fields['jc'], 0);
    });
  });

  group('MTU clamp — min(mtu, 1280) только при AWG-полях', () {
    const base = 'wireguard://P@h:51820?publickey=K&address=10.0.0.2/32';

    test('AWG без mtu → 1280 (вместо WG-дефолта)', () {
      final spec = parseWireguardUri('$base&jc=10')!;
      expect(spec.mtu, 1280);
      expect(spec.emit(TemplateVars.empty).map['mtu'], 1280);
    });

    test('AWG mtu=1420 → кламп до 1280', () {
      final spec = parseWireguardUri('$base&jc=10&mtu=1420')!;
      expect(spec.mtu, 1280);
    });

    test('AWG mtu=1200 (явно ниже) → уважаем', () {
      final spec = parseWireguardUri('$base&jc=10&mtu=1200')!;
      expect(spec.mtu, 1200);
    });

    test('AWG mtu=1280 (граница) → без изменений', () {
      final spec = parseWireguardUri('$base&jc=10&mtu=1280')!;
      expect(spec.mtu, 1280);
    });

    test('plain WG не трогаем: без mtu → 1408, mtu=1420 → 1420', () {
      expect(parseWireguardUri(base)!.mtu, 1408);
      expect(parseWireguardUri('$base&mtu=1420')!.mtu, 1420);
    });

    test('JSON endpoint: AWG без mtu → 1280, plain WG без mtu → null', () {
      Map<String, dynamic> entry({bool awg = false, int? mtu}) => {
            'type': 'wireguard',
            'tag': 't',
            'private_key': 'PRIV',
            'address': ['10.0.0.2/32'],
            'mtu': ?mtu,
            if (awg) 'jc': 10,
            'peers': [
              {
                'address': 'host',
                'port': 51821,
                'public_key': 'PUB',
                'allowed_ips': ['0.0.0.0/0'],
              }
            ],
          };
      expect((parseSingboxEntry(entry(awg: true)) as WireguardSpec).mtu, 1280);
      expect(
          (parseSingboxEntry(entry(awg: true, mtu: 1420)) as WireguardSpec).mtu,
          1280);
      expect((parseSingboxEntry(entry()) as WireguardSpec).mtu, isNull);
      expect((parseSingboxEntry(entry(mtu: 1420)) as WireguardSpec).mtu, 1420);
    });

    test('AmneziaWG INI без MTU → 1280', () {
      const conf = '[Interface]\n'
          'PrivateKey = PRIV\n'
          'Address = 10.0.0.2/32\n'
          'Jc = 10\n'
          '[Peer]\n'
          'PublicKey = PUB\n'
          'Endpoint = host.example.com:51821\n';
      expect(parseWireguardIni(conf)!.mtu, 1280);
    });
  });

  group('JSON / INI пути', () {
    test('parseSingboxEntry (endpoint JSON) → spec.awg, i пустые скип', () {
      final spec = parseSingboxEntry({
        'type': 'wireguard',
        'tag': 'awg',
        'private_key': 'PRIV',
        'address': ['10.0.0.2/32'],
        'mtu': 1408,
        'jc': 10,
        's1': 20,
        'h1': 1234567890,
        'i1': i3,
        'i2': '',
        'peers': [
          {
            'address': 'host',
            'port': 51821,
            'public_key': 'PUB',
            'allowed_ips': ['0.0.0.0/0'],
          }
        ],
      }) as WireguardSpec;
      expect(spec.awg!.fields['jc'], 10);
      expect(spec.awg!.fields['s1'], 20);
      expect(spec.awg!.fields['i1'], i3);
      expect(spec.awg!.fields.containsKey('i2'), false);
    });

    test('AmneziaWG INI (.conf) → spec.awg', () {
      const conf = '[Interface]\n'
          'PrivateKey = PRIV\n'
          'Address = 10.0.0.2/32\n'
          'MTU = 1408\n'
          'Jc = 10\n'
          'Jmin = 50\n'
          'S1 = 20\n'
          'H1 = 1234567890\n'
          'I1 = $i1\n'
          '[Peer]\n'
          'PublicKey = PUB\n'
          'Endpoint = host.example.com:51821\n'
          'PersistentKeepalive = 25\n';
      final spec = parseWireguardIni(conf)!;
      expect(spec.awg!.fields['jc'], 10);
      expect(spec.awg!.fields['jmin'], 50);
      expect(spec.awg!.fields['s1'], 20);
      expect(spec.awg!.fields['i1'], i1);
    });
  });
}
