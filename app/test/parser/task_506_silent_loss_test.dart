import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/engine/interpreter.dart'
    show normalizeBandwidthMbps;
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import 'engine_test_setup.dart';

/// §506 — ни одной молчаливой потери на пути разбора.
///
/// Диагностика четырёх пользовательских входов нашла два входа, терявшихся
/// ЦЕЛИКОМ и без единого слова: `vpn://<base64 голого .conf>` (0 узлов,
/// `dropped[]` пуст) и строки незнакомой схемы в теле подписки. Тесты ниже
/// закрывают оба, плюс общее правило: `null` от парсера без причины в
/// `dropped[]` — это баг, а не норма.

/// Тело входа A диагностики: AWG3-профиль wg-quick. Ключи — тестовые той же
/// ФОРМЫ (32 байта base64), что у настоящего входа: форму судит санитайзер, и
/// ключ неверной длины снял бы узел по `wg_key_invalid`.
const _awg3Conf = '''
[Interface]
PrivateKey = QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWY=
Address = 10.8.1.2/32
DNS = 8.8.8.8, 1.1.1.1
MTU = 1380
Jc = 4
Jmin = 48
Jmax = 128
S1 = 20
S2 = 119
S3 = 55
S4 = 17
H1 = 1
H2 = 2
H3 = 3
H4 = 4
HeaderProtectionKey = MTIzNDU2Nzg5MGFiY2RlZmdoaWprbG1ub3BxcnN0dXY=
ContentPaddingAddition = 17-29
RekeyAfterTime = 120-155
RekeyTimeout = 3-6
RejectAfterTime = 198-237
KeepaliveTimeout = 12-15
MaxHandshakeAttempts = 18-33
RandomTrailers = on
DisableCookies = on

# AmneziaWG entry-test
[Peer]
PublicKey = Z3l4d3Z1dHNycXBvbm1sa2ppaGdmZWRjYmEwOTg3NjU=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 94.250.255.65:56100
PersistentKeepalive = 2
''';

/// `vpn://` + base64 БЕЗ паддинга от голого текста `.conf` — ровно форма
/// входа A (паддинг дописывает `decodeBase64Safe`).
String _vpnLinkOfConf(String conf) {
  final b64 = base64Url.encode(utf8.encode(conf)).replaceAll('=', '');
  return 'vpn://$b64';
}

List<String> _codes(List<NodeWarning> ws) =>
    ws.map((w) => w is RegistryWarning ? w.code : w.runtimeType.toString()).toList();

void main() {
  setUpAll(loadEngineSections);

  group('§506 п.1 — vpn:// с голым .conf', () {
    test('тело подписки: 1 узел, а не 0', () {
      final dropped = <NodeWarning>[];
      final nodes = parseAll(decode(_vpnLinkOfConf(_awg3Conf)), dropped: dropped);

      expect(nodes, hasLength(1), reason: 'вход A терялся целиком и молча');
      expect(dropped, isEmpty, reason: 'тело разобрано — отбраковок быть не должно');
    });

    test('все AWG3-поля доезжают до emit', () {
      final nodes = parseAll(decode(_vpnLinkOfConf(_awg3Conf)));
      final map = nodes.single.emit(const TemplateVars()).map;

      expect(map['type'], 'wireguard');
      // Скаляры AWG 2.0 и AWG3.
      expect(map['jc'], 4);
      expect(map['jmin'], 48);
      expect(map['jmax'], 128);
      expect(map['s1'], 20);
      expect(map['s2'], 119);
      expect(map['s3'], 55);
      expect(map['s4'], 17);
      expect(map['h1'], 1);
      expect(map['h2'], 2);
      expect(map['h3'], 3);
      expect(map['h4'], 4);
      // Ключ защиты заголовков и поля-ДИАПАЗОНЫ — строками с дефисом
      // (`docs/PROTOCOLS.md:1199`, «passed through under the same names»).
      expect(map['header_protection_key'], isNotNull);
      expect(map['content_padding_addition'], '17-29');
      expect(map['rekey_after_time'], '120-155');
      expect(map['rekey_timeout'], '3-6');
      expect(map['reject_after_time'], '198-237');
      expect(map['keepalive_timeout'], '12-15');
      expect(map['max_handshake_attempts'], '18-33');
      expect(map['random_trailers'], isTrue);
      expect(map['disable_cookies'], isTrue);
    });

    test('identity как у того же .conf, поданного напрямую', () {
      // Тело одно и то же — обёртка `vpn://` не имеет права менять узел.
      final viaLink = parseAll(decode(_vpnLinkOfConf(_awg3Conf))).single;
      final direct = parseAll(decode(_awg3Conf)).single;

      final a = viaLink.emit(const TemplateVars()).map;
      final b = direct.emit(const TemplateVars()).map;
      // `tag` берётся из комментария под `[Peer]` у обоих путей, но сравнение
      // идёт по ТЕЛУ: identity узла — это конфиг, а не имя.
      expect(jsonEncode(a..remove('tag')), jsonEncode(b..remove('tag')));
    });

    test('строкой внутри URI-списка — тоже узел', () {
      final body = '${_vpnLinkOfConf(_awg3Conf)}\n';
      final dropped = <NodeWarning>[];
      final nodes = parseAll(decode(body), dropped: dropped);

      expect(nodes, hasLength(1));
      expect(dropped, isEmpty);
    });
  });

  group('§506 п.2 — причина вместо молчания', () {
    // §512 — схемой примера БОЛЬШЕ НЕ `amneziawg`: контракт 1.1.48 объявил её
    // в `scheme_in` секции wireguard, и теперь она даёт УЗЕЛ (регресс-тест —
    // `task_512_registry_schemes_test.dart`). Незнакомой берётся схема, которой
    // не ведёт ни одна секция реестра.
    // §512 (контракт 1.1.49, PARSING_PRINCIPLES §4.1) — код у НЕЗНАКОМОЙ СХЕМЫ теперь
    // `scheme_unsupported`: `protocol_unsupported` остался за записью, чей ТИП
    // неизвестен внутри опознанного тела.
    test('незнакомая схема: код scheme_unsupported со схемой в value', () {
      final verdict = XrayDropVerdict();
      final n = parseUri('nosuchproto://k@h.example:51820?jc=5',
          dropped: verdict);

      expect(n, isNull);
      final w = verdict.reason;
      expect(w, isA<RegistryWarning>());
      expect((w as RegistryWarning).code, 'scheme_unsupported');
      expect(w.value, 'nosuchproto',
          reason: 'пользователю нужна ИМЕННО схема — с ней он идёт к провайдеру');
    });

    test('незнакомая схема в теле подписки доезжает до dropped[]', () {
      const body = 'nosuchproto://k@h.example:51820?jc=5\n'
          'nosuchproto://k@h2.example:51821?jc=5\n';
      final dropped = <NodeWarning>[];
      final nodes = parseAll(decode(body), dropped: dropped);

      expect(nodes, isEmpty);
      expect(_codes(dropped), ['scheme_unsupported', 'scheme_unsupported'],
          reason: 'четыре такие строки входа D исчезали без следа');
    });

    // §512 — игнор служебных строк остался ТИХИМ ДЛЯ UI, но перестал быть
    // безымянным: реестр 1.1.48 дал info-код `service_record_ignored`.
    // Шторка §500 показывает причины только при нуле узлов, поэтому у живой
    // подписки код не виден, а у пустой отличает «команда панели» от
    // «потерянный узел».
    test('служебные строки провайдера — info-код, не ошибка', () {
      for (final line in [
        'incy://routing/onadd/eyJhIjoxfQ',
        'happ://routing/onadd/eyJhIjoxfQ',
      ]) {
        final verdict = XrayDropVerdict();
        expect(parseUri(line, dropped: verdict), isNull);
        final w = verdict.reason;
        expect(w, isA<RegistryWarning>(), reason: '$line — реестр 1.1.48');
        expect((w as RegistryWarning).code, 'service_record_ignored');
        expect(ContractRegistry.I.textFor(w.code)?.severity, 'info',
            reason: 'ошибкой команда соседнего клиента не является');
      }
    });

    test('служебная схема БЕЗ хвоста routing/ тихого игнора не заслуживает', () {
      // Реестр требует `path_prefix_fold: routing/`: про схему, объявившую
      // иное, не известно ничего.
      final verdict = XrayDropVerdict();
      expect(parseUri('incy://somethingelse/x', dropped: verdict), isNull);
      expect(verdict.reason?.code, 'scheme_unsupported');
    });

    test('строка без схемы вовсе — молчим (ввод не распознан, §500)', () {
      // `split('://')` отдал бы такую строку целиком, и код о протоколе
      // назвал бы мусор именем протокола.
      for (final junk in ['%%% not a subscription %%%', 'hello world', 'abc']) {
        final verdict = XrayDropVerdict();
        expect(parseUri(junk, dropped: verdict), isNull);
        expect(verdict.reason, isNull, reason: 'вход «$junk» — не ссылка вовсе');
      }
    });

    test('ссылка длиннее лимита — код uri_too_long, не молчание', () {
      final long = 'vless://${'a' * 70000}@h.example:443';
      final verdict = XrayDropVerdict();

      expect(parseUri(long, dropped: verdict), isNull);
      expect((verdict.reason as RegistryWarning).code, 'uri_too_long');
    });

    test('тело не декодировано — причина декодера в dropped[]', () {
      // Тело, которое НЕ доходит до построчного разбора: пустое после
      // декода. Строка без схемы туда бы дошла и получила свой код от
      // диспетчера — здесь проверяется именно ветка `DecodeFailure`.
      final dropped = <NodeWarning>[];
      final nodes = parseAll(decode('   \n\n  \n'), dropped: dropped);

      expect(nodes, isEmpty);
      expect(dropped, hasLength(1),
          reason: '«0 серверов» без причины не отличалось от пустого тела');
      final w = dropped.single as RegistryWarning;
      expect(w.code, 'core_rejected');
      expect(w.params['reason'], isNotEmpty,
          reason: 'текст причины — от декодера, дословно');
    });

    test('vpn:// с негодным payload — причина, а не пустой список', () {
      final dropped = <NodeWarning>[];
      final nodes = parseAll(decode('vpn://${base64Url.encode(utf8.encode('{"a":1}'))}'),
          dropped: dropped);

      expect(nodes, isEmpty);
      expect(dropped, isNotEmpty, reason: 'профиль без контейнеров WG/AWG');
    });
  });

  group('§506 п.3 — полоса с единицей', () {
    test('нормализатор bandwidth_mbps читает единицу, а не режет её', () {
      // Голое число — канон, менять нечего.
      expect(normalizeBandwidthMbps('100'), 100);
      // Мегабиты во всех написаниях.
      expect(normalizeBandwidthMbps('100mbps'), 100);
      expect(normalizeBandwidthMbps('100 Mbps'), 100);
      expect(normalizeBandwidthMbps('50m'), 50);
      expect(normalizeBandwidthMbps('  100MB  '), 100);
      // Гигабиты — множитель 1000, а не «ведущие цифры» (было бы 1).
      expect(normalizeBandwidthMbps('1gbps'), 1000);
      expect(normalizeBandwidthMbps('300Gbps'), 300000);
      // Килобиты и биты — вниз по шкале, округление ВВЕРХ (не ноль: ноль
      // значил бы «не задано», то есть ту же потерю).
      expect(normalizeBandwidthMbps('2000kbps'), 2);
      expect(normalizeBandwidthMbps('500kbps'), 1);
      expect(normalizeBandwidthMbps('1bps'), 1);
      // Дробное.
      expect(normalizeBandwidthMbps('1.5gbps'), 1500);
      expect(normalizeBandwidthMbps('0.5mbps'), 1);
    });

    test('не-полоса → null: судит санитайзер, значение едет как пришло', () {
      for (final bad in ['', 'fast', 'mbps', '100mb/s', '-5mbps', '0', '0mbps',
        '1e3', '100 200']) {
        expect(normalizeBandwidthMbps(bad), isNull, reason: 'вход «$bad»');
      }
    });
  });

}
