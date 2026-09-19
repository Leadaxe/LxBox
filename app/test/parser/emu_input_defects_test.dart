import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import 'engine_test_setup.dart';

/// §480 — дефекты входа, найденные проверкой на эмуляторе через Debug API
/// `addFromInput` (тот же путь, что вставка из буфера).
///
/// Вход берётся ровно тем же вызовом, что и у контроллера: `decode` опознаёт
/// вид документа, `parseAll` собирает узлы. Красное здесь = «вставил, узла
/// нет» на устройстве.
void main() {
  setUpAll(loadEngineSections);

  const xrayOutbound = '''
{
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "198.51.100.24",
        "port": 443,
        "users": [
          {"id": "b831381d-6324-4d53-ad4f-8cda48b30811",
           "encryption": "none",
           "flow": "xtls-rprx-vision"}
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "realitySettings": {
      "serverName": "example.com",
      "publicKey": "iGChnwFHnMDMs7oBcTJNFCsIrxHzFuFsvvIioNquUx0",
      "shortId": "0123abcd",
      "fingerprint": "chrome"
    }
  }
}''';

  nodesOf(String input) => parseAll(decode(input));

  /// Гейт контроллера (`_addJsonNodes`): вход, чей `flavor` не опознан,
  /// отвергается ДО разбора — `parseAll` его уже не видит. Дефект как раз
  /// тут и жил, поэтому форма проверяется отдельно от числа узлов.
  JsonFlavor flavorOf(String input) {
    final d = decode(input);
    return d is JsonConfig ? d.flavor : JsonFlavor.unknown;
  }

  group('Д-3 — Xray-JSON принимается всеми тремя формами входа', () {
    test('одиночный outbound-объект даёт узел', () {
      expect(nodesOf(xrayOutbound), isNotEmpty);
    });

    test('обёрнутый в outbounds[] даёт узел', () {
      expect(nodesOf('{"outbounds":[$xrayOutbound]}'), isNotEmpty);
    });

    test('полный конфиг с inbounds даёт узел', () {
      expect(
        nodesOf('{"inbounds":[{"port":10808,"protocol":"socks"}],'
            '"outbounds":[$xrayOutbound]}'),
        isNotEmpty,
      );
    });

    test('все три формы проходят гейт вставки, а не только разбор', () {
      // `unknown` здесь = «вставка ответит 400», даже если `parseAll` узел
      // собирает: контроллер до разбора не доходит.
      for (final input in [
        xrayOutbound,
        '{"outbounds":[$xrayOutbound]}',
        '[$xrayOutbound]',
        '[{"outbounds":[$xrayOutbound]}]',
      ]) {
        expect(flavorOf(input), JsonFlavor.xrayArray,
            reason: 'форма отвергается гейтом вставки: $input');
      }
    });

    test('sing-box-формы за Xray-ветки не уезжают', () {
      const sb = '{"type":"trojan","server":"h.example",'
          '"server_port":443,"password":"p"}';
      expect(flavorOf(sb), JsonFlavor.singboxOutbound);
      expect(flavorOf('[$sb]'), JsonFlavor.singboxArray);
      expect(flavorOf('{"log":{},"outbounds":[$sb]}'),
          JsonFlavor.singboxConfig);
    });
  });

  group('Д-4 — base64-подписка текстом принимается', () {
    const plain = 'vless://b831381d-6324-4d53-ad4f-8cda48b30811@'
        '198.51.100.24:443?encryption=none&security=tls&sni=example.com'
        '#one\n'
        'trojan://pass@198.51.100.25:443?sni=example.com#two\n'
        'ss://YWVzLTI1Ni1nY206cGFzcw==@198.51.100.26:8388#three';

    test('тот же текст без base64 даёт узлы (контроль)', () {
      expect(nodesOf(plain), hasLength(3));
    });

    test('std-алфавит с паддингом даёт те же узлы', () {
      expect(nodesOf(base64.encode(utf8.encode(plain))), hasLength(3));
    });

    test('url-safe алфавит без паддинга даёт те же узлы', () {
      final b64 = base64Url
          .encode(utf8.encode(plain))
          .replaceAll('=', '');
      expect(nodesOf(b64), hasLength(3));
    });

    test('переводы строк \\r\\n переживают кодирование', () {
      final crlf = plain.replaceAll('\n', '\r\n');
      expect(nodesOf(base64.encode(utf8.encode(crlf))), hasLength(3));
    });

    test('завёрнутое тело отличается от голого списка по исходному тексту',
        () {
      // Признак, по которому контроллер решает, снимать ли оболочку: у
      // голого списка `://` есть в САМОМ вводе, у завёрнутого — только
      // после распаковки. Обе формы дают `UriLines`, и без этого признака
      // они неразличимы.
      final wrapped = base64.encode(utf8.encode(plain));
      expect(decode(wrapped), isA<UriLines>());
      expect(wrapped.contains('://'), isFalse);
      expect(decode(plain), isA<UriLines>());
      expect(plain.contains('://'), isTrue);
    });
  });
}
