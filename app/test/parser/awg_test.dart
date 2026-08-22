import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/ini_parser.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §097 Phase 1 — AmneziaWG2 (AWG) сквозной проход: URI/JSON/INI → Awg → emit →
/// round-trip. По образцу singbox-launcher SPEC 073 (Фазы 1-4, 6).
// SPEC 103 D-023/D-030 — normalizeWGKey требует РОВНО 32 байта; короткие
// плейсхолдеры вроде "PRIV"/"PUB"/"K" больше не парсятся (null-skip).
// Валидные 32-байтные base64-заглушки для фикстур (см. test/parser/
// wireguard_edge_test.dart для канонического источника этой практики).
const _testPriv = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=';
const _testPub = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=';
const _testPsk = 'ccccccccccccccccccccccccccccccccccccccccccA=';

void main() {
  const i1 = '<b 0x000100002112a442><r 12>';
  const i3 = '<r 24>';
  final fullUri = 'wireguard://$_testPriv@host.example.com:51821'
      '?publickey=$_testPub&address=10.0.0.2/32&allowedips=0.0.0.0/0,::/0'
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
          'wireguard://$_testPriv@h:51820?publickey=$_testPub&address=10.0.0.2/32')!;
      expect(spec.awg, isNull);
    });

    test('битое число (jc=abc) → поле пропущено, парс не падает', () {
      final spec = parseWireguardUri(
          'wireguard://$_testPriv@h:51820?publickey=$_testPub&address=10.0.0.2/32&jc=abc&jmin=50')!;
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
          'wireguard://$_testPriv@h:51820?publickey=$_testPub&address=10.0.0.2/32')!;
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
          'wireguard://$_testPriv@h:51820?publickey=$_testPub&address=10.0.0.2/32&jc=0')!;
      expect(s1.awg!.fields['jc'], 0);
      final s2 = parseWireguardUri(s1.toUri())!;
      expect(s2.awg!.fields['jc'], 0);
    });
  });

  group('MTU clamp — min(mtu, 1280) только при AWG-полях', () {
    const base =
        'wireguard://$_testPriv@h:51820?publickey=$_testPub&address=10.0.0.2/32';

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

    // SPEC 103 D-026 — canon = Go: без явного mtu= в URI поле не эмитится
    // вовсе (ядро само ставит 1408). Было закреплено, что plain WG дефолтит
    // 1408 в самой модели — неканоничное поведение, тест обновлён.
    test('plain WG не трогаем: без mtu → не задан, mtu=1420 → 1420', () {
      expect(parseWireguardUri(base)!.mtu, isNull);
      expect(parseWireguardUri('$base&mtu=1420')!.mtu, 1420);
    });

    // §219/D-026 — plain WG без mtu НЕ дефолтит 1408 в модели (ядро само
    // ставит его); модель не зависит от источника парсинга (JSON vs URI).
    // AWG-clamp до 1280 без изменений.
    test('JSON endpoint: AWG без mtu → 1280, plain WG без mtu → не задан', () {
      Map<String, dynamic> entry({bool awg = false, int? mtu}) => {
            'type': 'wireguard',
            'tag': 't',
            'private_key': _testPriv,
            'address': ['10.0.0.2/32'],
            'mtu': ?mtu,
            if (awg) 'jc': 10,
            'peers': [
              {
                'address': 'host',
                'port': 51821,
                'public_key': _testPub,
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
          'PrivateKey = $_testPriv\n'
          'Address = 10.0.0.2/32\n'
          'Jc = 10\n'
          '[Peer]\n'
          'PublicKey = $_testPub\n'
          'Endpoint = host.example.com:51821\n';
      expect(parseWireguardIni(conf)!.mtu, 1280);
    });
  });

  group('JSON / INI пути', () {
    test('parseSingboxEntry (endpoint JSON) → spec.awg, i пустые скип', () {
      final spec = parseSingboxEntry({
        'type': 'wireguard',
        'tag': 'awg',
        'private_key': _testPriv,
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
            'public_key': _testPub,
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
          'PrivateKey = $_testPriv\n'
          'Address = 10.0.0.2/32\n'
          'MTU = 1408\n'
          'Jc = 10\n'
          'Jmin = 50\n'
          'S1 = 20\n'
          'H1 = 1234567890\n'
          'I1 = $i1\n'
          '[Peer]\n'
          'PublicKey = $_testPub\n'
          'Endpoint = host.example.com:51821\n'
          'PersistentKeepalive = 25\n';
      final spec = parseWireguardIni(conf)!;
      expect(spec.awg!.fields['jc'], 10);
      expect(spec.awg!.fields['jmin'], 50);
      expect(spec.awg!.fields['s1'], 20);
      expect(spec.awg!.fields['i1'], i1);
    });
  });

  group('§112 — ranged magic headers (h1–h4 как N-M)', () {
    const base =
        'wireguard://$_testPriv@h:51820?publickey=$_testPub&address=10.0.0.2/32';

    test('URI: h1=N-M → String, одиночный h2 → int', () {
      final awg =
          parseWireguardUri('$base&h1=43613244-384550127&h2=826869626')!.awg!;
      expect(awg.fields['h1'], '43613244-384550127');
      expect(awg.fields['h1'], isA<String>());
      expect(awg.fields['h2'], 826869626);
      expect(awg.fields['h2'], isA<int>());
    });

    test('битые формы (10-, a-b, -5, 1-2-3) → drop, парс не падает', () {
      final awg = parseWireguardUri(
          '$base&h1=10-&h2=a-b&h3=-5&h4=1-2-3&jc=4')!.awg!;
      expect(awg.fields.keys.where(Awg.headerKeys.contains), isEmpty);
      expect(awg.fields['jc'], 4);
    });

    test('JSON endpoint: h1 строкой N-M, h2 числом, h3="5" → int 5', () {
      final spec = parseSingboxEntry({
        'type': 'wireguard',
        'tag': 'awg',
        'private_key': _testPriv,
        'address': ['10.0.0.2/32'],
        'h1': '43613244-384550127',
        'h2': 826869626,
        'h3': '5',
        'peers': [
          {
            'address': 'host',
            'port': 51821,
            'public_key': _testPub,
            'allowed_ips': ['0.0.0.0/0'],
          }
        ],
      }) as WireguardSpec;
      expect(spec.awg!.fields['h1'], '43613244-384550127');
      expect(spec.awg!.fields['h2'], 826869626);
      expect(spec.awg!.fields['h3'], 5); // нормализация строки-числа
      expect(spec.awg!.fields['h3'], isA<int>());
    });

    test('emit: диапазон → JSON string, одиночное → number', () {
      final spec = parseWireguardUri('$base&h1=10-20&h2=30')!;
      final json = jsonEncode(spec.emit(TemplateVars.empty).map);
      expect(json, contains('"h1":"10-20"'));
      expect(json, contains('"h2":30'));
      expect(json, isNot(contains('"h2":"30"')));
    });

    test('round-trip share-URI с диапазоном', () {
      final s1 = parseWireguardUri('$base&h1=10-20&h2=30&jc=4')!;
      final s2 = parseWireguardUri(s1.toUri())!;
      expect(s2.awg!.fields, s1.awg!.fields);
      expect(s2.awg!.fields['h1'], '10-20');
    });

    test('INI реального awg2-экспорта (ranged H + S3/S4 + CPS I1) end-to-end',
        () {
      const conf = '[Interface]\n'
          'Address = 10.8.1.25/32\n'
          'DNS = 172.29.172.254, 1.0.0.1\n'
          'PrivateKey = $_testPriv\n'
          'Jc = 5\n'
          'Jmin = 10\n'
          'Jmax = 50\n'
          'S1 = 28\n'
          'S2 = 121\n'
          'S3 = 25\n'
          'S4 = 9\n'
          'H1 = 43613244-384550127\n'
          'H2 = 826869626-2105069164\n'
          'H3 = 2124774725-2141151992\n'
          'H4 = 2144594503-2146278491\n'
          'I1 = <b 0x084481800001>\n'
          'I2 = \n'
          '[Peer]\n'
          'PublicKey = $_testPub\n'
          'PresharedKey = $_testPsk\n'
          'AllowedIPs = 0.0.0.0/0, ::/0\n'
          'Endpoint = 64.188.69.128:44733\n'
          'PersistentKeepalive = 25\n';
      final spec = parseWireguardIni(conf)!;
      final f = spec.awg!.fields;
      expect(f['h1'], '43613244-384550127');
      expect(f['h4'], '2144594503-2146278491');
      expect(f['jc'], 5);
      expect(f['s4'], 9);
      expect(f['i1'], '<b 0x084481800001>');
      expect(f.containsKey('i2'), false);
      expect(spec.mtu, 1280);
      final map = spec.emit(TemplateVars.empty).map;
      expect(map['h1'], '43613244-384550127');
      expect(map['s3'], 25);
    });

    // §243 — имя файла → tag; AWG-поля при этом не теряются.
    test('awg2-INI с nameHint (имя файла) → tag = имя файла, AWG на месте',
        () {
      const conf = '[Interface]\n'
          'Address = 10.8.1.25/32\n'
          'PrivateKey = $_testPriv\n'
          'Jc = 5\n'
          'Jmin = 10\n'
          'Jmax = 50\n'
          'H1 = 43613244-384550127\n'
          'I1 = <b 0x084481800001>\n'
          '[Peer]\n'
          'PublicKey = $_testPub\n'
          'Endpoint = 64.188.69.128:44733\n';
      final spec = parseWireguardIni(conf, nameHint: 'awg2 export (home)')!;
      expect(spec.tag, 'awg2 export (home)');
      final f = spec.awg!.fields;
      expect(f['jc'], 5);
      expect(f['h1'], '43613244-384550127');
      expect(f['i1'], '<b 0x084481800001>');
      // Round-trip через синтетический URI (путь рестарта) — tag и AWG живы.
      final again = parseWireguardUri(spec.rawUri)!;
      expect(again.tag, 'awg2 export (home)');
      expect(again.awg!.fields['i1'], '<b 0x084481800001>');
    });
  });
}
