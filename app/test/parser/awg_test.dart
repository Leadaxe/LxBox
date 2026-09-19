import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
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
  // §480 W4 — гейт на ЗЕРКАЛО реестра: wireguard разбирает движок, и без
  // секций у схемы запасного пути не осталось.
  final mirrored = Directory('assets/contract/registry').existsSync();

  setUpAll(() async {
    if (!mirrored) return;
    await ContractRegistry.I.loadFromDirectory('assets/contract');
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
  });

  const i1 = '<b 0x000100002112a442><r 12>';
  const i3 = '<r 24>';
  final fullUri = 'wireguard://$_testPriv@host.example.com:51821'
      '?publickey=$_testPub&address=10.0.0.2/32&allowedips=0.0.0.0/0,::/0'
      '&mtu=1408&keepalive=25'
      '&jc=10&jmin=50&jmax=100&s1=20&s2=20&s3=60&s4=60'
      '&h1=1234567890&h2=1234567891&h3=1234567892&h4=1234567893'
      '&i1=${Uri.encodeQueryComponent(i1)}'
      '&i3=${Uri.encodeQueryComponent(i3)}#awg-server';

  // §480 W4 — ФАЙЛ ТЕПЕРЬ ГРУЗИТ РЕЕСТР И СЕКЦИИ, и это смена предмета
  // проверки, а не правка под зелёный.
  //
  // Прежняя редакция намеренно проверяла работу БЕЗ реестра: запасное число
  // `kAwgMtuFallback` ставил конвейер сам, потому что реестр не был
  // обязательным условием работы приложения (§460 — не загрузился, живём как
  // до него). Фича 480 это отменила критерием 7 спеки: «движок без реестра не
  // работает вовсе, рукописного запасного пути не остаётся, отсутствие
  // реестра в сборке — ошибка сборки». Запасного пути у wireguard больше нет,
  // и проверять его поведение стало нечем.
  //
  // Потолок MTU при этом никуда не делся — его ставит САНИТАЙЗЕР по
  // `body.fields.mtu` (`max_when`, §473), и ровно это группа ниже и проверяет.
  group('§473 — потолок MTU по реестру', () {
    String wg(String extra) => 'wireguard://$_testPriv@h.example:51820'
        '?publickey=$_testPub&address=10.0.0.2/32$extra#n';

    test('AWG с mtu=1420 заклампится потолком реестра', () {
      final spec = parseWireguardUri(wg('&jc=4&mtu=1420'))!;
      expect(spec.mtu, kAwgMtuFallback,
          reason: 'без потолка узел уехал бы в ядро с 1420: туннель '
              'поднимается, данные не идут');
      expect(spec.emit(TemplateVars.empty).map['mtu'], kAwgMtuFallback);
      // Замена не молчит: код объявлен реестром (`awg_mtu_clamped`).
      expect(spec.warnings.whereType<RegistryWarning>().map((w) => w.code),
          contains('awg_mtu_clamped'));
    });

    test('AWG без mtu получает потолок дефолтом реестра, кодов нет', () {
      final spec = parseWireguardUri(wg('&jc=4'))!;
      expect(spec.mtu, kAwgMtuFallback);
      expect(spec.warnings, isEmpty, reason: 'подстановка — не замена');
    });

    test('обычный WG потолка не получает вовсе', () {
      expect(parseWireguardUri(wg('&mtu=1420'))!.mtu, 1420);
      expect(parseWireguardUri(wg(''))!.mtu, isNull,
          reason: 'ядро берёт свой 1408; наш дефолт ломал бы identity');
    });
  });

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

    test('битое число (jc=abc) → поле пропущено; одинокий jmin снят (§24.6)',
        () {
      // §463 — `jmin` без `jmax` снимается правилом `requires` реестра:
      // отсутствующий `jmax` ядро читает как 0 и валит ВЕСЬ конфиг
      // («amneziawg: jmin (50) must be <= jmax (0)»). Раньше `jmin=50`
      // оставался в теле и ронял всё.
      final spec = parseWireguardUri(
          'wireguard://$_testPriv@h:51820?publickey=$_testPub&address=10.0.0.2/32&jc=abc&jmin=50')!;
      expect(spec.awg, isNull, reason: 'оба AWG-поля сняты — набор пуст');
      // Узел при этом остаётся AmneziaWG: ссылка просила AWG, и кламп MTU
      // 1280 — свойство запрошенного протокола, а не уцелевших полей.
      expect(spec.mtu, 1280);
    });

    test('пара jmin+jmax переживает разбор (§24.6 — requires выполнен)', () {
      final spec = parseWireguardUri(
          'wireguard://$_testPriv@h:51820?publickey=$_testPub&address=10.0.0.2/32&jmin=50&jmax=100')!;
      expect(spec.awg!.fields['jmin'], 50);
      expect(spec.awg!.fields['jmax'], 100);
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
    // ставит его).
    //
    // §473 (контракт 1.1.5) — ПОДСТАНОВКА дефолта у AWG-узла осталась той же
    // на всех входах, а ЗАМЕНА завышенного значения на JSON-входе снята:
    // тело sing-box написали в собственной форме ядра человек или подписка, и
    // молча переписывать его нельзя (`max_when.except_sources`, решение
    // владельца 18.09.2026). Узел вместо замены получает info-код
    // `awg_mtu_high` — его ставит санитайзер по дословной карте, см.
    // `test/contract/parse_warnings_test.dart`. Это единственное место
    // контракта, где вход узла влияет на результат, и парность входов здесь
    // нарушена НАМЕРЕННО.
    test('JSON endpoint: AWG без mtu → 1280, завышенный mtu сохраняется', () {
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
      expect((parseSingboxEntry(entry(awg: true)) as WireguardSpec).mtu, 1280,
          reason: 'подстановка дефолта работает и на JSON-входе');
      expect(
          (parseSingboxEntry(entry(awg: true, mtu: 1420)) as WireguardSpec).mtu,
          1420,
          reason: '§473 — написанное в форме ядра не переписывается');
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
          // §463 — `Jmin` без `Jmax` снял бы себя правилом `requires`
          // реестра (одинокий jmin роняет весь конфиг), поэтому в фикстуре
          // задана пара: тест проверяет разбор полей, а не это правило.
          'Jmin = 50\n'
          'Jmax = 1000\n'
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

    // §481 (контракт 1.1.11) — КОД теперь ставит реестр, а не разбор: маппер
    // отдаёт мусор санитайзеру как есть, и поле снимается с
    // `awg_header_invalid` на всех входах, а не только на ссылке (проверяет
    // `body_sanitizer_test.dart`). Здесь реестр не загружен (см. шапку файла),
    // и последним читателем тела остаётся `Awg.fromJson` — он мусор не
    // понимает и поле не заводит. Наблюдаемый итог тот же, что был: заголовков
    // в узле нет, `jc` цел, парс не падает.
    test('битые формы (10-, a-b, -5, 1-2-3) → поля нет, парс не падает', () {
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
      // §456 — источник — INI; имя при перечитывании — hint (тег записи).
      final again =
          parseWireguardIni(spec.rawSource, nameHint: 'awg2 export (home)')!;
      expect(again.tag, 'awg2 export (home)');
      expect(again.awg!.fields['i1'], '<b 0x084481800001>');
    });
  });

  // §421 — AmneziaWG 3.0/3.1: защита заголовка, паддинг, хвосты, тайминги.
  // Эталон — Go awg3.go (SPEC 123); ключи синтетические (32 байта, не нули).
  group('§421 — AmneziaWG 3.x', () {
    const hk = 'Bw4VHCMqMTg/Rk1UW2JpcHd+hYyTmqGor7a9xMvS2eA=';
    // '+' и '/' ключа в query — percent-encoded, как эмитит buildQuery.
    final hkQ = Uri.encodeQueryComponent(hk).replaceAll('+', '%20');
    String uri(String extra, {String base = ''}) =>
        'wireguard://$_testPriv@host.example.com:30565'
        '?publickey=$_testPub&address=10.8.1.7/32&allowedips=0.0.0.0/0,::/0'
        '$base$extra#awg3';
    const s = '&s1=55&s2=42&s3=40&s4=12';

    test('полный набор: диапазоны строкой, одиночное числом, булевы true, '
        'keepalive "25-35", MTU 1376 клампится до 1280', () {
      final spec = parseWireguardUri(uri(
          '&mtu=1376&keepalive=25-35&jc=4&jmin=10&jmax=50$s&h1=1&h2=2&h3=3&h4=4'
          '&headerprotectionkey=$hkQ&contentpaddingaddition=10-100'
          '&rekeyaftertime=100-120&rekeytimeout=3-7&rejectaftertime=150-180'
          '&keepalivetimeout=5-15&maxhandshakeattempts=15'
          '&randomtrailers=on&disablecookies=on'))!;
      final f = spec.awg!.fields;
      expect(f['header_protection_key'], hk);
      expect(f['content_padding_addition'], '10-100');
      expect(f['rekey_after_time'], '100-120');
      expect(f['max_handshake_attempts'], 15); // одиночное → int
      expect(f['random_trailers'], true);
      expect(f['disable_cookies'], true);
      expect(f['h1'], 1); // H1–H4 = 1..4 нормальны при защите заголовка
      expect(spec.mtu, 1280); // AWG3 клампится как AWG2 (решение 2026-09-05)
      expect(spec.peers.single.persistentKeepalive, '25-35');
      // §473 — замена потолком БОЛЬШЕ НЕ МОЛЧИТ: человек написал 1376 и
      // обязан узнать, что уехало 1280. Код один, и он про `mtu`; прочих
      // предупреждений у полного набора нет.
      expect(spec.warnings.map((w) => w is RegistryWarning ? w.code : '$w'),
          ['awg_mtu_clamped']);
      expect((spec.warnings.single as RegistryWarning).value, '1376');
      final map = spec.emit(TemplateVars.empty).map;
      expect(map['random_trailers'], true);
      expect(map['rekey_timeout'], '3-7');
      expect(map['mtu'], 1280);
      expect(
          (map['peers'] as List).first['persistent_keepalive_interval'], '25-35');
    });

    test('ключ защиты с сырым "+" в query переживает разбор (не пробел)', () {
      final spec = parseWireguardUri(uri('$s&headerprotectionkey=$hk'))!;
      expect(spec.awg!.fields['header_protection_key'], hk);
    });

    test('url-safe/без паддинга ключ нормализуется к std base64', () {
      final urlSafe = hk.replaceAll('+', '-').replaceAll('/', '_')
          .replaceAll('=', '');
      final spec = parseWireguardUri(uri('$s&headerprotectionkey=$urlSafe'))!;
      expect(spec.awg!.fields['header_protection_key'], hk);
    });

    test('булевы off/false/0/пусто → ключа нет; on/true/1 → true', () {
      for (final v in ['off', 'false', '0', '']) {
        final spec = parseWireguardUri(uri('$s&randomtrailers=$v'))!;
        expect(spec.awg!.fields.containsKey('random_trailers'), false,
            reason: 'randomtrailers=$v');
        expect(spec.emit(TemplateVars.empty).map.containsKey('random_trailers'),
            false);
      }
      for (final v in ['on', 'true', '1', 'On']) {
        final spec = parseWireguardUri(uri('$s&disablecookies=$v'))!;
        expect(spec.awg!.fields['disable_cookies'], true, reason: v);
      }
    });

    // §481 (контракт 1.1.11) — КОД у таймингов ставит теперь РЕЕСТР, и путь у
    // него — имя поля ТЕЛА (`content_padding_addition`), как нормирует корпус,
    // а не имя параметра ссылки (`contentpaddingaddition`), которое ставил
    // маппер. Здесь реестр не загружен (см. шапку файла), поэтому кода нет
    // вовсе; проверяет его `contract_test.dart`
    // (`awg3_timing_range_reversed_dropped`) и `body_sanitizer_test.dart`.
    // Булевы (`randomtrailers`/`disablecookies`) с контракта 1.1.23 ведёт
    // секция реестра: у записи объявлен `value_map` с `on_no_match: keep`,
    // негодное написание доезжает до тела и снимается там правилом поля
    // (`type: bool`, `on_invalid: drop` с кодом `awg3_field_invalid`).
    // Рукописного `Awg3FieldInvalidWarning` на этом входе больше не
    // возникает, а реестр под этим файлом не загружен (см. шапку) — поэтому
    // кода здесь нет вовсе, ровно как у остальных строк таблицы. Проверяет
    // его `contract_test.dart` по корпусу.
    test('таблица негативов: поле снято, узел жив', () {
      const cases = <String, String>{
        'contentpaddingaddition': 'abc',
        'rekeyaftertime': '120-100', // N > M — НЕ свопается (в отличие от h)
        'rekeytimeout': '3-',
        'rejectaftertime': '-5',
        'keepalivetimeout': '1-2-3',
        'maxhandshakeattempts': '4294967296', // > uint32
        'randomtrailers': 'maybe',
        'disablecookies': 'yes',
      };
      cases.forEach((param, value) {
        final spec = parseWireguardUri(uri('$s&$param=$value'))!;
        final json = Awg.awg3ParamToJson[param]!;
        expect(spec.awg!.fields.containsKey(json), false,
            reason: '$param=$value должно быть снято');
        // Маркер AWG3 даже при невалидном поле: узел — AmneziaWG, дефолт 1280.
        expect(spec.mtu, 1280);
      });
    });

    test('h1–h4 перевёрнутый диапазон по-прежнему свопается (контраст)', () {
      final spec = parseWireguardUri(uri('$s&h1=300-200'))!;
      expect(spec.awg!.fields['h1'], '200-300');
    });

    // §481 (контракт 1.1.11) — рукописный `awg3NodeError` СНЯТ: узел роняет
    // реестр (`awg3_header_key_invalid` / `awg3_padding_too_short`, оба
    // `drop_node`), и роняет С КОДОМ и на входе sing-box тоже, чего рукописная
    // проверка не умела вовсе.
    //
    // §480 W4 — ожидание ПЕРЕВЁРНУТО. Прежняя редакция ждала, что узел ЖИВЁТ:
    // реестр в этом файле не грузился, и судить значение было некому. Фича 480
    // отменила такой прогон критерием 7 («движок без реестра не работает
    // вовсе»), реестр здесь теперь загружен — и правило отрабатывает.
    test('битый ключ защиты роняет узел правилом реестра', () {
      const zero = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
      for (final bad in ['not-base64!', 'AQIDBAUGBwgJCgsMDQ4PEA==', zero]) {
        expect(parseWireguardUri(uri('$s&headerprotectionkey=$bad')), isNull,
            reason: bad);
      }
    });

    test('короткий паддинг при ключе защиты роняет узел; без ключа он легален '
        '(AWG2-поведение)', () {
      expect(
          parseWireguardUri(
              uri('&s1=55&s2=42&s3=40&s4=11&headerprotectionkey=$hkQ')),
          isNull,
          reason: 'nonce шифра заголовка берётся из первых 12 байт паддинга');
      expect(parseWireguardUri(uri('&s1=5&s4=0')), isNotNull,
          reason: 'без ключа защиты короткий паддинг — обычный AWG2');
    });

    test('random_trailers + широкий диапазон h: поля на месте', () {
      final spec = parseWireguardUri(
          uri('$s&h1=1000-70000&randomtrailers=on'))!;
      expect(spec.awg!.fields['h1'], '1000-70000');
      expect(spec.awg!.fields['random_trailers'], true);
      // §480 W4 — info-кода `awg3_random_trailers_wide_headers` здесь БОЛЬШЕ
      // НЕТ, и это не потеря значения, а переезд СУЖДЕНИЯ. Он рождался в
      // рукописном маппере (`Awg.randomTrailersWithWideHeaders`), а судит он
      // ДВА поля разом — `random_trailers` и ширину `h1`–`h4`. Маппер значения
      // не судит вовсе, а правило поверх пары полей умеет объявлять только
      // реестр, и сегодня он его не объявляет: запись — запрос к лаунчеру
      // (`body.fields`, условие по паре). До неё кода нет ни у одной стороны.
      final narrow = parseWireguardUri(
          uri('$s&h1=1000-2000&randomtrailers=on'))!;
      expect(narrow.warnings, isEmpty);
    });

    test('keepalive: мусор пропускается; один диапазонный keepalive = '
        'маркер AWG3 (узел AWG даже без AWG2-полей → кламп 1280)', () {
      final junk = parseWireguardUri(uri('&keepalive=abc'))!;
      expect(junk.peers.single.persistentKeepalive, isNull);
      expect(junk.mtu, isNull); // plain WG без mtu — поле не эмитим
      final ranged = parseWireguardUri(uri('&mtu=1376&keepalive=25-35'))!;
      expect(ranged.awg, isNull);
      expect(ranged.peers.single.persistentKeepalive, '25-35');
      expect(ranged.mtu, 1280);
      // Явно ниже 1280 — уважаем, как у AWG2.
      expect(parseWireguardUri(uri('&mtu=1200&keepalive=25-35'))!.mtu, 1200);
    });

    test('AWG2 без AWG3-маркеров клампится как раньше', () {
      final spec = parseWireguardUri(uri('&mtu=1376&jc=4$s'))!;
      expect(spec.mtu, 1280);
    });

    test('round-trip writeQuery → fromQuery без потерь (булевы → on)', () {
      final awg = Awg({
        'jc': 4,
        's1': 55, 's2': 42, 's3': 40, 's4': 12,
        'h1': '1000-2000',
        'header_protection_key': hk,
        'content_padding_addition': '10-100',
        'rekey_after_time': 100,
        'random_trailers': true,
      });
      final q = <String, String>{};
      awg.writeQuery(q);
      expect(q['randomtrailers'], 'on');
      expect(q['contentpaddingaddition'], '10-100');
      expect(q['rekeyaftertime'], '100');
      expect(q['headerprotectionkey'], hk);
      expect(q.containsKey('random_trailers'), false);
      final again = Awg.fromQuery(q)!;
      expect(again.fields, awg.fields);
    });

    test('round-trip share-URI: spec → toUri → parse сохраняет AWG3-набор', () {
      final spec = parseWireguardUri(uri(
          '&mtu=1200&keepalive=25-35&jc=4$s&h1=1&headerprotectionkey=$hkQ'
          '&rekeytimeout=3-7&randomtrailers=on&disablecookies=on'))!;
      final again = parseWireguardUri(spec.toUri())!;
      expect(again.awg!.fields, spec.awg!.fields);
      expect(again.mtu, 1200);
      expect(again.peers.single.persistentKeepalive, '25-35');
      // Написание истины эмит берёт у САМОЙ записи — первым ключом её
      // `value_map` (`on`), а не общим `1`: иначе поменялся бы сохранённый
      // rawSource ручного узла и то, что уезжает по Copy link.
      expect(spec.toUri(), contains('randomtrailers=on'));
    });

    test('JSON endpoint: AWG3-ключи, keepalive строкой, mtu цел (§473); '
        'битый ключ → null', () {
      final entry = <String, dynamic>{
        'type': 'wireguard',
        'tag': 'awg3',
        'mtu': 1376,
        'address': ['10.8.1.7/32'],
        'private_key': _testPriv,
        'peers': [
          {
            'address': 'host.example.com',
            'port': 30565,
            'public_key': _testPub,
            'allowed_ips': ['0.0.0.0/0'],
            'persistent_keepalive_interval': '25-35',
          }
        ],
        'jc': 4, 's1': 55, 's2': 42, 's3': 40, 's4': 12,
        'header_protection_key': hk,
        'content_padding_addition': '10-100',
        'rekey_timeout': 5,
        'random_trailers': true,
        'disable_cookies': false,
      };
      final spec = parseSingboxEntry(entry) as WireguardSpec;
      final f = spec.awg!.fields;
      expect(f['header_protection_key'], hk);
      expect(f['content_padding_addition'], '10-100');
      expect(f['rekey_timeout'], 5);
      expect(f['random_trailers'], true);
      expect(f.containsKey('disable_cookies'), false); // false = ключа нет
      // §473 — вход `singbox`: 1376 из тела сохраняется, узел получает
      // info-код `awg_mtu_high`. На ссылке та же величина заменилась бы на
      // 1280 (тест «AWG2 без AWG3-маркеров клампится как раньше»).
      expect(spec.mtu, 1376);
      expect(spec.peers.single.persistentKeepalive, '25-35');
      // §481 — годность ключа судит реестр (в этом файле он не загружен);
      // разбор тела её больше не проверяет и узла не теряет.
      final bad = Map<String, dynamic>.from(entry)
        ..['header_protection_key'] = 'AQIDBAUGBwgJCgsMDQ4PEA==';
      expect(parseSingboxEntry(bad), isNotNull);
    });

    test('INI: AWG3-ключи [Interface], PersistentKeepalive = 25-35', () {
      const conf = '[Interface]\n'
          'Address = 10.8.1.7/32\n'
          'PrivateKey = $_testPriv\n'
          'Jc = 4\n'
          'S1 = 55\n'
          'S2 = 42\n'
          'S3 = 40\n'
          'S4 = 12\n'
          'H1 = 1\n'
          'HeaderProtectionKey = $hk\n'
          'ContentPaddingAddition = 10-100\n'
          'RekeyAfterTime = 100-120\n'
          'RandomTrailers = on\n'
          'DisableCookies = off\n'
          '[Peer]\n'
          'PublicKey = $_testPub\n'
          'AllowedIPs = 0.0.0.0/0, ::/0\n'
          'Endpoint = 203.0.113.9:30565\n'
          'PersistentKeepalive = 25-35\n';
      final spec = parseWireguardIni(conf)!;
      final f = spec.awg!.fields;
      expect(f['header_protection_key'], hk);
      expect(f['content_padding_addition'], '10-100');
      expect(f['rekey_after_time'], '100-120');
      expect(f['random_trailers'], true);
      expect(f.containsKey('disable_cookies'), false);
      expect(spec.peers.single.persistentKeepalive, '25-35');
      expect(spec.mtu, 1280); // AWG3 без MTU — дефолт AmneziaWG 1280
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §450 — awg://<base64 .conf>: вторая форма share-link
  // ══════════════════════════════════════════════════════════════════════════
  group('§450 awg://<base64 .conf>', () {
    const hk = 'ddddddddddddddddddddddddddddddddddddddddddY=';
    const conf = '[Interface]\n'
        'PrivateKey = $_testPriv\n'
        'Address = 10.101.0.2/32\n'
        'DNS = 1.1.1.1\n'
        'Jc = 120\n'
        'Jmin = 23\n'
        'Jmax = 911\n'
        'S1 = 56\n'
        'S2 = 48\n'
        'S3 = 32\n'
        'S4 = 16\n'
        'H1 = 1\n'
        'H2 = 2\n'
        'H3 = 3\n'
        'H4 = 4\n'
        'HeaderProtectionKey = $hk\n'
        'ContentPaddingAddition = 16-64\n'
        'RekeyAfterTime = 3000-4000\n'
        'RandomTrailers = on\n'
        '[Peer]\n'
        'PublicKey = $_testPub\n'
        'PresharedKey = $_testPsk\n'
        'AllowedIPs = 0.0.0.0/0\n'
        'Endpoint = 91.247.235.94:51821\n'
        'PersistentKeepalive = 25\n';
    final payload = base64.encode(utf8.encode(conf));

    test('метка из фрагмента, AWG3-поля и MTU-клэмп доезжают', () {
      final link = 'awg://$payload#AmneziaWG-3.1';
      final spec = parseUri(link) as WireguardSpec?;
      expect(spec, isNotNull, reason: 'форма не распознана — узел потерян');
      expect(spec!.tag, 'AmneziaWG-3.1');
      expect(spec.server, '91.247.235.94');
      expect(spec.port, 51821);
      expect(spec.privateKey, _testPriv);
      final peer = spec.peers.single;
      expect(peer.publicKey, _testPub);
      expect(peer.preSharedKey, _testPsk);
      expect(peer.allowedIps, ['0.0.0.0/0']); // без лишнего ::/0 из дефолта
      final f = spec.awg!.fields;
      expect(f['jc'], 120);
      expect(f['h4'], 4);
      expect(f['header_protection_key'], hk);
      expect(f['content_padding_addition'], '16-64');
      expect(f['rekey_after_time'], '3000-4000');
      expect(f['random_trailers'], true);
      expect(spec.mtu, 1280); // §421 — кламп AWG3
      // Контракт 1.1.23+ — `wgconf_dns_ignored` ЗАРАБОТАЛ и на этой форме:
      // `DNS` из `.conf` относится к системному резолверу, в тело узла не
      // едет, и потеря теперь названа кодом. Прежде снималось молча.
      expect(
        spec.warnings.whereType<RegistryWarning>().map((w) => w.code),
        ['wgconf_dns_ignored'],
      );
    });

    test('источник узла — исходная ссылка, не синтетический wireguard://', () {
      final link = 'awg://$payload#AmneziaWG-3.1';
      expect((parseUri(link) as WireguardSpec).rawSource, link);
    });

    test('без фрагмента метка = хост Endpoint, а не фолбэк WireGuard', () {
      final spec = parseUri('awg://$payload') as WireguardSpec?;
      expect(spec!.tag, '91.247.235.94');
    });

    test('схемы wg:// и wireguard:// принимают ту же форму', () {
      for (final scheme in ['wg', 'wireguard']) {
        final spec = parseUri('$scheme://$payload#n') as WireguardSpec?;
        expect(spec?.server, '91.247.235.94', reason: scheme);
      }
    });

    test('base64 без [Interface] → узел отброшен (parse_error)', () {
      expect(parseUri('awg://aGVsbG8gd29ybGQsIG5vdCBhIGNvbmY=#junk'), isNull);
    });

    test('не-base64 payload → узел отброшен', () {
      expect(parseUri('awg://!!!not base64!!!#junk'), isNull);
    });

    test('форма key@host:port не перехватывается conf-веткой', () {
      final spec = parseUri(fullUri) as WireguardSpec?;
      expect(spec!.server, 'host.example.com');
      expect(spec.rawSource, fullUri);
    });

    test('второй [Interface]-блок игнорируется: один link = один узел', () {
      final two = base64.encode(utf8.encode('$conf\n$conf'));
      final spec = parseUri('awg://$two#two') as WireguardSpec?;
      expect(spec!.peers.length, 1);
      expect(spec.server, '91.247.235.94');
    });
  });
}
