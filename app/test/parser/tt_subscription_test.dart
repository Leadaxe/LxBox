// §717 итерация 3 (контракт 1.1.176) — подписка TrustTunnel: ответ узла
// (объект JSON) печатается ссылкой `tt://` распаковщиком `container_link`,
// ссылка-указатель заводит подписку, учётные данные из адреса уходят
// заголовком `Authorization: Basic`.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/engine/tlv.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/subscription/input_helpers.dart';
import 'package:lxbox/services/subscription/sources.dart';

import 'engine_test_setup.dart';

List<int> _str(int tag, String s) => encodeTlv(tag, utf8.encode(s));

String _link(List<List<int>> fields) => 'tt://?'
    '${base64Url.encode([for (final f in fields) ...f]).replaceAll('=', '')}';

const _answer = {
  'version': 1,
  'hostname': 'vpn.example.com',
  'address': '1.2.3.4:443',
  'username': 'alice',
  'password': 's3cr3t',
  'has_ipv6': true,
  'upstream_protocol': 'http2',
  'anti_dpi': false,
  'skip_verification': false,
  'name': 'Example VPN',
};

void main() {
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  group('ответ подписки → ссылка', () {
    test('объект печатается ссылкой, узел — как из ссылки', () {
      final decoded = decode(jsonEncode(_answer));
      expect(decoded, isA<UriLines>());
      final lines = (decoded as UriLines).lines;
      // Версия ответа (1) версией контейнера не является: пишется 2.
      expect(lines, [
        _link([
          encodeTlv(0x00, writeVarint(2)),
          _str(0x01, 'vpn.example.com'),
          _str(0x05, 'alice'),
          _str(0x06, 's3cr3t'),
          _str(0x02, '1.2.3.4:443'),
          _str(0x0C, 'Example VPN'),
        ]),
      ]);
      final n = parseUri(lines.single)! as UnknownTypeSpec;
      expect(n.type, 'trusttunnel');
      expect(n.label, 'Example VPN');
      expect(n.body['server'], '1.2.3.4');
      // Происхождение узла — ссылка, а не объект.
      expect(n.rawSource, lines.single);
      expect(n.warnings.whereType<RegistryWarning>(), isEmpty);
    });

    test('http3, PEM и поля вне тела — те же коды, что у ссылки', () {
      final decoded = decode(jsonEncode({
        ..._answer,
        'upstream_protocol': 'http3',
        'custom_sni': 'sni.example.org',
        'dns_upstreams': ['tls://1.1.1.1'],
      }));
      final n = parseUri((decoded as UriLines).lines.single)!
          as UnknownTypeSpec;
      expect(n.body['quic'], true);
      expect(
          n.warnings.whereType<RegistryWarning>().map((w) => w.params['field']),
          unorderedEquals(['custom_sni', 'dns_upstreams']));
    });

    test('объект sing-box и неполный объект видом не являются', () {
      expect(decode(jsonEncode({..._answer, 'type': 'trusttunnel'})),
          isNot(isA<UriLines>()));
      expect(decode(jsonEncode({..._answer}..remove('password'))),
          isNot(isA<UriLines>()));
    });

    test('значение не того типа — вид не распакован', () {
      expect(decode(jsonEncode({..._answer, 'certificate': 'not a pem'})),
          isA<UriLines>());
      expect(
          decode(jsonEncode({
            ..._answer,
            'certificate': '-----BEGIN CERTIFICATE-----\n@@@',
          })),
          isNot(isA<UriLines>()));
    });
  });

  group('ссылка-указатель на подписку', () {
    final pointer = _link([
      encodeTlv(0x00, writeVarint(2)),
      _str(0x0E, 'https://alice:s3cr3t@sub.example.com/s/abc'),
    ]);

    test('отказ несёт адрес в параметре subscription_url', () {
      final dropped = XrayDropVerdict();
      expect(parseUri(pointer, dropped: dropped), isNull);
      expect(dropped.reason?.code, 'tt_subscription_only');
      expect(dropped.reason?.params['subscription_url'],
          'https://alice:s3cr3t@sub.example.com/s/abc');
    });

    test('принимающая сторона получает адрес подписки', () {
      expect(subscriptionUrlOfLink(pointer),
          'https://alice:s3cr3t@sub.example.com/s/abc');
    });

    test('полный узел и чужой отказ указателем не являются', () {
      final node = _link([
        _str(0x01, 'h.example'),
        _str(0x02, '1.2.3.4:443'),
        _str(0x05, 'u'),
        _str(0x06, 'p'),
        _str(0x0E, 'https://sub.example.com/x'),
      ]);
      expect(subscriptionUrlOfLink(node), isNull);
      expect(subscriptionUrlOfLink('tt://?@@@'), isNull);
      expect(subscriptionUrlOfLink('https://sub.example.com/x'), isNull);
    });
  });

  group('Basic Auth из userinfo адреса', () {
    test('заголовок из логина и пароля, percent снят', () {
      expect(basicAuthHeader(Uri.parse('https://sub.example.com/x')), isEmpty);
      expect(
          basicAuthHeader(Uri.parse('https://alice:p%40ss%3Aw@sub.example.com/x')),
          {'Authorization': 'Basic ${base64.encode(utf8.encode('alice:p@ss:w'))}'});
    });

    test('отказ сервера не показывает пароль из адреса', () async {
      final client = MockClient((req) async => http.Response('', 401));
      await expectLater(
          fetchRaw(const UrlSource('https://alice:s3cr3t@sub.example.com/s/abc'),
              client: client),
          throwsA(predicate((e) =>
              '$e'.contains('HTTP 401') && !'$e'.contains('s3cr3t'))));
    });

    test('загрузчик подписки отдаёт заголовок серверу', () async {
      String? seen;
      final client = MockClient((req) async {
        seen = req.headers['Authorization'];
        return http.Response(jsonEncode(_answer), 200);
      });
      final res = await fetchRaw(
          const UrlSource('https://alice:s3cr3t@sub.example.com/s/abc'),
          client: client);
      expect(seen, 'Basic ${base64.encode(utf8.encode('alice:s3cr3t'))}');
      expect(decode(res.body), isA<UriLines>());
    });
  });
}
