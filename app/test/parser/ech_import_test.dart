import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/tls_spec.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §320 — ECH из подписок. Xray-форма `ech=<query-name>+<resolver-URL>`
/// раньше отбрасывалась молча: терялось сокрытие SNI от DPI, ровно то, за чем
/// такие ноды и берут.
///
/// Левая часть — имя для HTTPS-DNS-запроса, отличное от SNI, т.е.
/// `query_server_name` ядра. Резолвер прокинуть некуда (в OutboundECHOptions
/// поля нет — ядро идёт через общий dnsRouter), отбрасываем с warning'ом.
void main() {
  Map<String, dynamic> tlsOf(NodeSpec n) =>
      n.emitRaw(const TemplateVars()).map['tls'] as Map<String, dynamic>;

  group('парсинг ech', () {
    test('name+resolver → query_server_name, резолвер в warning', () {
      final n = parseUri(
        'trojan://humanity@172.67.149.60:443?path=%2Fassignment'
        '&security=tls&host=www.ignitelimit.com'
        '&ech=ip.gs%2Budp%3A%2F%2F8.8.8.8&type=ws'
        '&sni=www.ignitelimit.com#node',
      )!;
      expect(tlsOf(n)['ech'], {
        'enabled': true,
        'query_server_name': 'ip.gs',
      });
      expect(
        n.warnings.whereType<EchResolverIgnoredWarning>().single,
        const EchResolverIgnoredWarning('udp://8.8.8.8'),
      );
    });

    test('только имя → без warning', () {
      final n = parseUri(
        'trojan://pw@example.com:443?type=ws&path=%2Fx&security=tls'
        '&ech=encryptedsni.com&sni=example.com#node',
      )!;
      expect(tlsOf(n)['ech'],
          {'enabled': true, 'query_server_name': 'encryptedsni.com'});
      expect(n.warnings.whereType<EchResolverIgnoredWarning>(), isEmpty);
    });

    test('пустое / none → ECH не включаем', () {
      for (final v in ['', 'none', 'NONE', '  ']) {
        final n = parseUri(
          'trojan://pw@example.com:443?type=ws&path=%2Fx&security=tls'
          '&ech=${Uri.encodeQueryComponent(v)}&sni=example.com#node',
        )!;
        expect(tlsOf(n).containsKey('ech'), isFalse, reason: 'ech=$v');
      }
    });

    test('ech отсутствует → ключа нет', () {
      final n = parseUri(
        'trojan://pw@example.com:443?type=ws&path=%2Fx'
        '&security=tls&sni=example.com#node',
      )!;
      expect(tlsOf(n).containsKey('ech'), isFalse);
    });

    test('имя пустое при заданном резолвере → ECH включаем (ядро спросит sni)',
        () {
      final n = parseUri(
        'trojan://pw@example.com:443?type=ws&path=%2Fx&security=tls'
        '&ech=%2Budp%3A%2F%2F8.8.8.8&sni=example.com#node',
      )!;
      expect(tlsOf(n)['ech'], {'enabled': true});
      expect(n.warnings.whereType<EchResolverIgnoredWarning>(), hasLength(1));
    });

    test('echfq не читается совсем (legacy pq-schemes роняет конфиг ядра)', () {
      final n = parseUri(
        'trojan://humanity@104.17.111.8:443?type=ws&host=www.ignitelimit.com'
        '&path=%2Fassignment&security=tls&sni=www.ignitelimit.com'
        '&fp=chrome&echfq=none#node',
      )!;
      expect(tlsOf(n).containsKey('ech'), isFalse);
      expect(n.warnings.whereType<EchResolverIgnoredWarning>(), isEmpty);
    });

    test('security=none → TLS выключен, ech не всплывает', () {
      final n = parseUri(
        'trojan://pw@example.com:443?type=tcp&security=none'
        '&ech=ip.gs#node',
      )!;
      expect(tlsOf(n), {'enabled': false});
    });
  });

  group('vless: ECH во всех TLS-ветвях', () {
    test('plain TLS', () {
      final n = parseUri(
        'vless://11111111-2222-3333-4444-555555555555@example.com:443'
        '?type=ws&path=%2Fx&security=tls&ech=ip.gs&sni=example.com#node',
      )!;
      expect(tlsOf(n)['ech'], {'enabled': true, 'query_server_name': 'ip.gs'});
    });

    test('REALITY — ECH сохраняется рядом', () {
      const pbk = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw';
      final n = parseUri(
        'vless://11111111-2222-3333-4444-555555555555@example.com:443'
        '?security=reality&pbk=$pbk&sid=ab&ech=ip.gs&sni=example.com#node',
      )!;
      final tls = tlsOf(n);
      expect(tls['ech'], {'enabled': true, 'query_server_name': 'ip.gs'});
      expect((tls['reality'] as Map)['public_key'], pbk);
    });
  });

  group('round-trip', () {
    test('toUri несёт ech=, второй проход даёт тот же блок', () {
      final src = 'trojan://pw@example.com:443?type=ws&path=%2Fx'
          '&security=tls&ech=ip.gs%2Budp%3A%2F%2F8.8.8.8&sni=example.com#node';
      final n = parseUri(src)! as TrojanSpec;
      expect(n.tls.ech, const EchSpec(queryServerName: 'ip.gs'));

      final uri = n.toUri();
      expect(Uri.parse(uri).queryParameters['ech'], 'ip.gs');

      // Резолвер уже отброшен — во втором проходе warning не повторяется.
      final again = parseUri(uri)!;
      expect(tlsOf(again)['ech'],
          {'enabled': true, 'query_server_name': 'ip.gs'});
      expect(again.warnings.whereType<EchResolverIgnoredWarning>(), isEmpty);
    });
  });

  group('EchSpec', () {
    test('пустое имя → только enabled', () {
      expect(const EchSpec().toSingbox(), {'enabled': true});
    });

    test('равенство по значению', () {
      expect(const EchSpec(queryServerName: 'a'),
          const EchSpec(queryServerName: 'a'));
      expect(const EchSpec(queryServerName: 'a'),
          isNot(const EchSpec(queryServerName: 'b')));
    });
  });
}
