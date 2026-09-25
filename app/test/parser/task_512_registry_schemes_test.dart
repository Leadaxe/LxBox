import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/uri_pipeline.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/subscription/input_helpers.dart';

import '../contract_paths.dart';
import 'engine_test_setup.dart';

/// §512 — СПИСОК СХЕМ ИЗ РЕЕСТРА и исполнение контракта 1.1.49.
///
/// Отчёт §506 назвал точный разрыв: реестр `detect.scheme_in` уже нёс имена
/// схем, а диспетчер дублировал их литералами в трёх местах, поэтому
/// `amneziawg` из `scheme_in` контракта 1.1.48 сам по себе НЕ заработал бы —
/// строка по-прежнему падала бы в `default`. Тесты ниже стерегут, что набор
/// схем живёт в данных, а не в коде.

/// Ключи фикстуры — ТЕСТОВЫЕ той же ФОРМЫ, что у живого входа D (32 байта
/// base64): форму судит санитайзер, и ключ неверной длины снял бы узел по
/// `wg_key_invalid`. Адрес — корпусный, i1 укорочена до той же формы
/// (`<b 0x…><r 32>`, percent-энкоденная, с литеральными `+`).
const _privateKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA%3D';
const _publicKey = 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE%3D';
const _presharedKey = 'Bw4VHCMqMTg%2FRk1UW2JpcHd%2BhYyTmqGor7a9xMvS2eA%3D';
const _hpk = 'MTIzNDU2Nzg5MGFiY2RlZmdoaWprbG1ub3BxcnN0dXY%3D';

/// Одна строка входа D: все AWG3-поля, h1–h4 ДИАПАЗОНАМИ.
///
/// [dns] дописывается В QUERY (а не после `#`): у живого входа D параметр
/// стоит там же, и правило реестра читает именно `query.dns`.
String _awgLink(String scheme,
        {String host = 'host.example.com', String dns = ''}) =>
    '$scheme://$_privateKey@$host:9494'
    '?address=10.200.0.6%2F32'
    '${dns.isEmpty ? '' : '&dns=$dns'}'
    '&h1=11758-81984&h2=129715-170451&h3=216120-285919&h4=305575-388085'
    '&i1=%3Cb+0xc300000001088cf07a7e17c709%3E%3Cr+32%3E'
    '&jc=5&jmax=50&jmin=10&mtu=1280'
    '&headerprotectionkey=$_hpk'
    '&presharedkey=$_presharedKey'
    '&publickey=$_publicKey'
    '&s1=57&s2=105&s3=52&s4=12#DE-example-awg';

void main() {
  setUpAll(loadEngineSections);

  group('§512 — набор схем из реестра, а не из литералов', () {
    test('реестр отвечает набором, и он не пуст', () {
      final set = registryUriSchemes();
      expect(set, isNotNull,
          reason: 'секции `mappers.uri` загружены — набор обязан быть');
      // Канон и алиасы написания приезжают вместе: по ним и маршрутизирует
      // диспетчер, а не по типу тела.
      expect(set, containsAll(<String>['vless', 'trojan', 'wireguard', 'awg']));
    });

    test('контракт 1.1.48/49 — `amneziawg` в наборе БЕЗ правки кода', () {
      expect(registryUriSchemes(), contains('amneziawg'),
          reason: 'написание объявлено `scheme_in` секции wireguard');
      expect(registrySchemeType('amneziawg'), 'wireguard',
          reason: 'та же секция, тот же тип тела — не второй протокол');
    });

    test('рабочий набор ШИРЕ каждой из сторон: реестр добавляет, не отнимает', () {
      // Реестр `scheme_in` НЕ объявляет `wg://` намеренно: написание знает
      // только Dart (`wireguard.json` → note, разрыв с Go IsDirectLink).
      // Поэтому объединение, а не замена — иначе синк молча снял бы живое
      // написание, и это выглядело бы следствием контракта, а не решением.
      final working = pipelineSchemes();
      expect(working, containsAll(kPipelineSchemes),
          reason: 'ни одно живое написание не теряется при живом реестре');
      expect(working, contains('amneziawg'),
          reason: 'а новое из реестра добавляется без правки кода');
      expect(registryUriSchemes(), isNot(contains('wg')),
          reason: 'снимок разрыва: `wg` держат литералы, и это НЕ опечатка — '
              'уедет вместе с решением владельца, а не попутно');
    });

    test('классификатор вставки берёт тот же набор', () {
      // §480 W6 — вторая копия списка уже успела разъехаться с первой
      // (`naive+quic`, `socks4`, `masque`); теперь копии нет вовсе.
      expect(isDirectLink('amneziawg://k@h.example:9494?jc=5'), isTrue);
      expect(isDirectLink('nosuchproto://k@h.example:9494'), isFalse);
    });
  });

  group('§512 — `amneziawg://` даёт узел со всеми полями', () {
    test('одна ссылка — узел, а не отбраковка', () {
      final verdict = XrayDropVerdict();
      final n = parseUri(_awgLink('amneziawg'), dropped: verdict);

      expect(n, isNotNull,
          reason: 'до 1.1.48 строка падала в `default` (вход D, 4 строки)');
      expect(verdict.reason, isNull);
    });

    test('поля живого входа доезжают до emit', () {
      final map = parseUri(_awgLink('amneziawg'))!.emit(const TemplateVars()).map;

      expect(map['type'], 'wireguard');
      // Диапазоны h1–h4 — строками с дефисом, как у формы `.conf`.
      expect(map['h1'], '11758-81984');
      expect(map['h2'], '129715-170451');
      expect(map['h3'], '216120-285919');
      expect(map['h4'], '305575-388085');
      expect(map['i1'], '<b 0xc300000001088cf07a7e17c709><r 32>');
      expect(map['header_protection_key'], isNotNull);
      expect(map['jc'], 5);
      expect(map['s1'], 57);
      final peer = (map['peers'] as List).single as Map;
      expect(peer['pre_shared_key'], isNotNull);
      expect(peer['port'], 9494);
    });

    test('identity равна той же ссылке с `awg://`', () {
      // Написание схемы — свойство ССЫЛКИ, не узла: тело обязано совпасть
      // дословно, иначе тот же сервер задвоился бы при импорте.
      final viaFull = parseUri(_awgLink('amneziawg'))!.emit(const TemplateVars()).map;
      final viaShort = parseUri(_awgLink('awg'))!.emit(const TemplateVars()).map;

      expect(viaFull, equals(viaShort));
    });

    test('четыре строки `amneziawg://` в теле — четыре узла', () {
      final body = [
        _awgLink('amneziawg', host: 'h1.example.com'),
        _awgLink('amneziawg', host: 'h2.example.com'),
        _awgLink('amneziawg', host: 'h3.example.com'),
        _awgLink('amneziawg', host: 'h4.example.com'),
      ].join('\n');
      final dropped = <NodeWarning>[];
      final nodes = parseAll(decode(body), dropped: dropped);

      expect(nodes, hasLength(4), reason: 'вход D: 4 строки исчезали молча');
      expect(dropped, isEmpty);
      for (final n in nodes) {
        expect(n.emit(const TemplateVars()).map['h1'], '11758-81984');
      }
    });

    test('`dns` из query в тело не едет и даёт wgconf_dns_ignored', () {
      // У формы `.conf` правило было и раньше; кейс корпуса 1.1.48 сверяет
      // его и у URI-формы.
      final n = parseUri(_awgLink('amneziawg', dns: '1.1.1.1%2C+1.0.0.1'))!;
      final map = n.emit(const TemplateVars()).map;

      expect(map.containsKey('dns'), isFalse);
      expect(
        [for (final w in n.warnings.whereType<RegistryWarning>()) w.code],
        contains('wgconf_dns_ignored'),
      );
    });
  });

  group('§512 — служебные схемы из реестра', () {
    test('`incy://routing/…` — info-код реестра, а не ошибка', () {
      final verdict = XrayDropVerdict();
      expect(parseUri('incy://routing/onadd/eyJhIjoxfQ', dropped: verdict),
          isNull);
      final w = verdict.reason;
      expect(w?.code, 'service_record_ignored');
      expect(ContractRegistry.I.textFor(w!.code)?.severity, 'info',
          reason: 'команда соседнему клиенту ошибкой не является');
    });

    test('живая подписка: узлы есть, служебная строка не мешает', () {
      // Шторка §500 показывает причины только при нуле узлов, поэтому
      // info-код в UI не всплывает — ровно то, чего требует §44 контракта.
      final body = '${_awgLink('amneziawg', host: 'h1.example.com')}\n'
          'incy://routing/onadd/eyJhIjoxfQ\n';
      final dropped = <NodeWarning>[];
      final nodes = parseAll(decode(body), dropped: dropped);

      expect(nodes, hasLength(1));
      expect(
        [for (final w in dropped.whereType<RegistryWarning>()) w.code],
        ['service_record_ignored'],
      );
    });
  });
  // §512 — ИСПОЛНЕНИЕ 1.1.49 на формах живых входов. Числа и поля взяты с
  // четырёх реальных подписок (диагностика §506); секреты заменены на
  // тестовые той же ФОРМЫ.
  group('§512 — формы живых входов', () {
    test('C: полоса hysteria2 с суффиксом → мегабиты (normalize: bandwidth_mbps)',
        () {
      // `"100mbps"` / `"300mbps"`: до 1.1.49 `type: int` на такой строке давал
      // отсутствие значения, и полоса терялась МОЛЧА.
      const body = '{"outbounds":[{"tag":"hy2","protocol":"hysteria",'
          '"settings":{"version":2,"address":"ge.example.com","port":443},'
          '"streamSettings":{"network":"hysteria","security":"tls",'
          '"tlsSettings":{"serverName":"ge.example.com","alpn":["h3"]},'
          '"hysteriaSettings":{"version":2,"auth":"testauth00000000",'
          '"up":"100mbps","down":"300mbps","udpIdleTimeout":120},'
          '"finalmask":{"udp":[{"type":"salamander",'
          '"settings":{"password":"testobfspassword"}}]}}}]}';
      final nodes = parseAll(decode(body));
      expect(nodes, hasLength(1));
      final map = nodes.single.emit(const TemplateVars()).map;

      expect(map['type'], 'hysteria2');
      expect(map['up_mbps'], 100, reason: 'единица ЧИТАЕТСЯ, а не срезается');
      expect(map['down_mbps'], 300);
      // §512 — обфускация из `finalmask.udp[0]`: секрет лежит вложенно в
      // `settings.password`, и без записей 1.1.48 salamander терялся целиком —
      // узел приезжал и НЕ ПОДНИМАЛСЯ.
      expect(map['obfs'],
          {'type': 'salamander', 'password': 'testobfspassword'});
    });

    test('B: одиночный конфиг Xray — узел, а не «missing type»', () {
      // Вид `xray_config` (prio 35): диалект называет `protocol` у элемента.
      // Прежде одиночный конфиг уходил ветке sing-box и давал ноль узлов.
      const body = '{"outbounds":[{"tag":"single","protocol":"vless",'
          '"settings":{"vnext":[{"address":"sw.example.com","port":443,'
          '"users":[{"id":"c271958daff043cb",'
          '"encryption":"mlkem768x25519plus.native.0rtt.dGVzdGtleQ"}]}]},'
          '"streamSettings":{"network":"tcp","security":"reality",'
          '"realitySettings":{"serverName":"sw.example.com",'
          '"fingerprint":"firefox",'
          '"publicKey":"mnL3vXjnwysMjlryreyJyrXZ5eaEuhDTpCD3r7UoBBU",'
          '"shortId":"d48964df7db5"}}}]}';
      final nodes = parseAll(decode(body));
      expect(nodes, hasLength(1));
      final map = nodes.single.emit(const TemplateVars()).map;

      expect(map['type'], 'vless');
      // mlkem уезжает ДОСЛОВНО: ядро пина v1.14.1-lx.8 поле принимает (§506).
      expect((map['tls'] as Map?)?['reality']?['enabled'], isTrue);
    });

    test('D: смешанное тело — узлы всех схем плюс служебная строка', () {
      // Состав живого входа D: vless + amneziawg + vpn, и одна команда панели.
      final body = [
        'vless://c271958daff043cb@v1.example.com:443?type=tcp&security=none#V1',
        _awgLink('amneziawg', host: 'a1.example.com'),
        'incy://routing/onadd/eyJhIjoxfQ',
      ].join('\n');
      final dropped = <NodeWarning>[];
      final nodes = parseAll(decode(body), dropped: dropped);

      expect(nodes, hasLength(2),
          reason: 'vless + amneziawg; incy узлом не был');
      expect(
        [for (final w in dropped.whereType<RegistryWarning>()) w.code],
        ['service_record_ignored'],
        reason: 'ни одной МОЛЧАЛИВОЙ потери и ни одной ложной ошибки',
      );
    });
  });

  // §551 — маршрут схем кешируется на состав секций: сброс обязан случаться
  // при перезагрузке черновиков и реестра, иначе схема, приехавшая
  // контрактом, не видна до перезапуска приложения.
  group('§551 — кеш маршрута схем сбрасывается при перезагрузке', () {
    tearDown(loadEngineSections);

    test('новая схема черновика видна после loadDrafts', () async {
      expect(pipelineSchemes(), isNot(contains('zz551')));
      expect(registrySchemeType('zz551'), isNull);
      final dir = Directory.systemTemp.createTempSync('lx551');
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/uri').createSync();
      File('${dir.path}/uri/zz551proto.json').writeAsStringSync(jsonEncode({
        'mappers': {
          'uri': {
            'detect': {
              'scheme_in': ['zz551'],
            },
            'params': <String, dynamic>{},
          },
        },
      }));
      await MapperSections.I
          .loadDrafts(dir: dir.path, files: const ['uri/zz551proto']);
      expect(pipelineSchemes(), contains('zz551'));
      expect(registryUriSchemes(), contains('zz551'));
      expect(registrySchemeType('ZZ551'), 'zz551proto');
    });

    test('перезагрузка реестра даёт новый состав секций', () async {
      final before = MapperSections.I.typesFor('uri');
      expect(identical(MapperSections.I.typesFor('uri'), before), isTrue);
      await ContractRegistry.I.loadFromDirectory(kRegistryRoot);
      expect(identical(MapperSections.I.typesFor('uri'), before), isFalse);
      expect(MapperSections.I.typesFor('uri'), before);
    });
  });
}
