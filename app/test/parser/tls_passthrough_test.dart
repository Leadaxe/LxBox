import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/tls_spec.dart';
import 'package:lxbox/services/parser/json_parsers.dart';

/// §454 / issue #140 — TLS-поля тела узла проходят разбор → эмит по
/// allowlist'у `OutboundTLSOptions` ядра (норма контракта TASKS_LXBOX §22).
void main() {
  const pem = '-----BEGIN CERTIFICATE-----\nMII…c=\n-----END CERTIFICATE-----\n';

  Map<String, dynamic> emitOf(Map<String, dynamic> entry) =>
      parseSingboxEntry(entry)!.emit(TemplateVars.empty).map;

  Map<String, dynamic> naive({Map<String, dynamic> tls = const {}}) => {
        'type': 'naive',
        'tag': 'naive-out',
        'server': '1.2.3.4',
        'server_port': 443,
        'username': 'user',
        'password': 'password',
        'tls': {'enabled': true, 'server_name': 'server.com', ...tls},
      };

  group('naive (#140)', () {
    test('certificate строкой переживает round-trip строкой', () {
      final m = emitOf(naive(tls: {'certificate': pem}));
      final tls = m['tls'] as Map;
      expect(tls['certificate'], pem);
      expect(tls['server_name'], 'server.com');
      expect(tls.keys.toList(), ['enabled', 'server_name', 'certificate']);
    });

    test('certificate массивом — массивом; certificate_path — как есть', () {
      final m = emitOf(naive(tls: {
        'certificate': [pem, pem],
        'certificate_path': '/sdcard/ca.pem',
      }));
      final tls = m['tls'] as Map;
      expect(tls['certificate'], [pem, pem]);
      expect(tls['certificate_path'], '/sdcard/ca.pem');
    });

    test('§459 naive принимает ech-объект (outbound.go читает блок целиком)',
        () {
      final m = emitOf(naive(tls: {
        'ech': {'enabled': true, 'config': ['pem'], 'query_server_name': 'ip.gs'},
      }));
      final tls = m['tls'] as Map;
      expect(tls['ech'],
          {'enabled': true, 'config': ['pem'], 'query_server_name': 'ip.gs'});
      expect(tls.keys.toList(), ['enabled', 'server_name', 'ech']);
    });

    test('§459 naive: ech не-объект отброшен', () {
      final tls = emitOf(naive(tls: {'ech': 'x'}))['tls'] as Map;
      expect(tls.containsKey('ech'), isFalse);
    });

    test('мусорные TLS-поля naive срезаны (ядро отвергает фаталом)', () {
      final m = emitOf(naive(tls: {
        'certificate': pem,
        'insecure': true,
        'alpn': ['h2'],
        'min_version': '1.3',
        'disable_sni': true,
        'fragment': true,
        'kernel_tx': true,
        'certificate_public_key_sha256': ['abc'],
        'utls': {'enabled': true, 'fingerprint': 'chrome'},
        'client_certificate': pem,
      }));
      final tls = m['tls'] as Map;
      expect(tls.keys.toList(), ['enabled', 'server_name', 'certificate']);
    });

    test('rawSource naive-узла — его объект (переезд в папку не теряет)', () {
      final entry = naive(tls: {'certificate': pem});
      final spec = parseSingboxEntry(entry)!;
      expect(jsonDecode(spec.rawSource), entry);
    });
  });

  group('общий allowlist', () {
    Map<String, dynamic> vless(Map<String, dynamic> tls) => {
          'type': 'vless',
          'tag': 'v',
          'server': 'h.example.com',
          'server_port': 443,
          'uuid': '5c8c9a1e-1c7a-4f3d-9d6b-2b1a1c3d4e5f',
          'tls': {'enabled': true, 'server_name': 'h.example.com', ...tls},
        };

    test('все сквозные ключи vless сохраняются, порядок = структура ядра', () {
      final input = <String, dynamic>{
        'alpn': ['h2', 'http/1.1'],
        'insecure': true,
        'disable_sni': true,
        'min_version': '1.2',
        'max_version': '1.3',
        'cipher_suites': ['TLS_AES_128_GCM_SHA256'],
        'curve_preferences': 'X25519',
        'certificate': pem,
        'certificate_path': '/a.pem',
        'certificate_public_key_sha256': 'pin1',
        'client_certificate': [pem],
        'client_certificate_path': '/c.pem',
        'client_key': pem,
        'client_key_path': '/k.pem',
        'fragment': true,
        'fragment_fallback_delay': '500ms',
        'record_fragment': true,
        'kernel_tx': true,
        'kernel_rx': true,
        'utls': {'enabled': true, 'fingerprint': 'firefox'},
      };
      final tls = emitOf(vless(input))['tls'] as Map;
      expect(tls.keys.toList(), [
        'enabled',
        'server_name',
        'alpn',
        'insecure',
        'disable_sni',
        'min_version',
        'max_version',
        'cipher_suites',
        'curve_preferences',
        'certificate',
        'certificate_path',
        'certificate_public_key_sha256',
        'client_certificate',
        'client_certificate_path',
        'client_key',
        'client_key_path',
        'fragment',
        'fragment_fallback_delay',
        'record_fragment',
        'kernel_tx',
        'kernel_rx',
        'utls',
      ]);
      expect(tls['curve_preferences'], 'X25519'); // строка осталась строкой
      expect(tls['client_certificate'], [pem]); // массив — массивом
      expect(tls['certificate_public_key_sha256'], ['pin1']);
      expect(tls['min_version'], '1.2');
    });

    test('значение не того типа — поле отброшено, узел жив', () {
      final tls = emitOf(vless({
        'certificate': 42,
        'certificate_path': ['x'],
        'min_version': 1.3,
        'disable_sni': 'yes',
        'fragment': false,
        'cipher_suites': [1, '', 'TLS_AES_256_GCM_SHA384'],
      }))['tls'] as Map;
      expect(tls.containsKey('certificate'), isFalse);
      expect(tls.containsKey('certificate_path'), isFalse);
      expect(tls.containsKey('min_version'), isFalse);
      expect(tls.containsKey('disable_sni'), isFalse);
      expect(tls.containsKey('fragment'), isFalse);
      expect(tls['cipher_suites'], ['TLS_AES_256_GCM_SHA384']);
    });

    test('§459 ech-объект проходит как есть, неизвестные ключи — нет', () {
      final tls = emitOf(vless({
        'ech': {
          'enabled': true,
          'config': ['x'],
          'config_path': '/etc/ech.pem',
          'query_server_name': 'ip.gs',
        },
        'foo': 'bar',
      }))['tls'] as Map;
      expect(tls['ech'], {
        'enabled': true,
        'config': ['x'],
        'config_path': '/etc/ech.pem',
        'query_server_name': 'ip.gs',
      });
      expect(tls.containsKey('foo'), isFalse);
    });

    test('§459 ech не-объект отброшен молча', () {
      for (final bad in <dynamic>['x', 1, true, ['a']]) {
        final tls = emitOf(vless({'ech': bad}))['tls'] as Map;
        expect(tls.containsKey('ech'), isFalse, reason: 'bad=$bad');
      }
    });

    test('§459 ech стоит между kernel_rx и utls (порядок структуры ядра)', () {
      final tls = emitOf(vless({
        'kernel_rx': true,
        'ech': {'enabled': true},
        'utls': {'enabled': true, 'fingerprint': 'chrome'},
      }))['tls'] as Map;
      final keys = tls.keys.toList();
      expect(keys.indexOf('kernel_rx') < keys.indexOf('ech'), isTrue);
      expect(keys.indexOf('ech') < keys.indexOf('utls'), isTrue);
    });

    test('без сквозных ключей эмит прежний байт в байт (parity)', () {
      final tls = emitOf(vless({
        'alpn': ['h2'],
        'insecure': true,
        'utls': {'enabled': true, 'fingerprint': 'chrome'},
      }))['tls'] as Map;
      expect(jsonEncode(tls),
          '{"enabled":true,"server_name":"h.example.com","alpn":["h2"],'
          '"insecure":true,"utls":{"enabled":true,"fingerprint":"chrome"}}');
    });

    test('hysteria2 (QUIC): certificate проходит, utls срезан', () {
      final tls = emitOf({
        'type': 'hysteria2',
        'tag': 'hy',
        'server': 'h.example.com',
        'server_port': 443,
        'password': 'p',
        'tls': {
          'enabled': true,
          'server_name': 'h.example.com',
          'certificate': pem,
          'utls': {'enabled': true, 'fingerprint': 'chrome'},
        },
      })['tls'] as Map;
      expect(tls['certificate'], pem);
      expect(tls.containsKey('utls'), isFalse);
    });
  });

  group('TlsSpec ==', () {
    test('пин и сквозные ключи входят в равенство', () {
      const a = TlsSpec(enabled: true, serverName: 's');
      final b = a.copyWith(passthrough: {'certificate': pem});
      final c = a.copyWith(certificatePublicKeySha256: ['pin']);
      expect(a == b, isFalse);
      expect(a == c, isFalse);
      expect(b == a.copyWith(passthrough: {'certificate': pem}), isTrue);
      expect(b.hashCode, a.copyWith(passthrough: {'certificate': pem}).hashCode);
    });
  });
}
