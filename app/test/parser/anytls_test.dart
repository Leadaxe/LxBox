import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §269 — AnyTLS: `anytls://password@host:port?...#label`.
void main() {
  group('parseAnyTls — базовый разбор', () {
    test('password/host/port/label, TLS всегда on', () {
      final s = parseUri('anytls://secret@srv.example.com:8443#AT-01');
      expect(s, isA<AnyTlsSpec>());
      final a = s as AnyTlsSpec;
      expect(a.password, 'secret');
      expect(a.server, 'srv.example.com');
      expect(a.port, 8443);
      expect(a.label, 'AT-01');
      expect(a.tag, 'AT-01');
      expect(a.protocol, 'anytls');
      expect(a.tls.enabled, isTrue, reason: 'AnyTLS всегда поверх TLS');
      expect(a.tls.serverName, 'srv.example.com', reason: 'sni default = host');
    });

    test('дефолтный порт 443', () {
      final a = parseUri('anytls://pw@h.example') as AnyTlsSpec;
      expect(a.port, 443);
    });

    test('percent-encoded password декодируется', () {
      final a = parseUri('anytls://p%40ss%3Aword@h.example:443') as AnyTlsSpec;
      expect(a.password, 'p@ss:word');
    });

    test('пустой password → null (AnyTLS требует пароль)', () {
      expect(parseUri('anytls://@h.example:443'), isNull);
      expect(parseUri('anytls://h.example:443'), isNull);
    });

    test('без host → null', () {
      expect(parseUri('anytls://'), isNull);
    });

    test('IPv6 host', () {
      final a = parseUri('anytls://pw@[2001:db8::1]:8443#v6') as AnyTlsSpec;
      expect(a.server, '2001:db8::1');
      expect(a.port, 8443);
    });

    test('security=none игнорируется — TLS всё равно on', () {
      final a = parseUri('anytls://pw@h.example:443?security=none') as AnyTlsSpec;
      expect(a.tls.enabled, isTrue);
    });

    test('security=none НЕ теряет sni/fp/alpn/insecure (§269 ревью)', () {
      // Ранее форсинг TLS затирал параметры при security=none.
      final a = parseUri('anytls://pw@h.example:8443'
          '?security=none&sni=cdn.example.com&fp=chrome'
          '&alpn=h2,http/1.1&allowInsecure=1#S') as AnyTlsSpec;
      expect(a.tls.enabled, isTrue);
      expect(a.tls.serverName, 'cdn.example.com');
      expect(a.tls.fingerprint, 'chrome');
      expect(a.tls.alpn, ['h2', 'http/1.1']);
      expect(a.tls.insecure, isTrue);
      // insecure → InsecureTlsWarning выставлен.
      expect(a.warnings.whereType<InsecureTlsWarning>(), isNotEmpty);
    });
  });

  group('parseAnyTls — TLS-параметры (trojan-конвенция)', () {
    test('sni/fp/alpn/insecure', () {
      final a = parseUri('anytls://pw@h.example:8443'
          '?sni=cdn.example.com&fp=chrome&alpn=h2,http/1.1&allowInsecure=1'
          '#S') as AnyTlsSpec;
      expect(a.tls.serverName, 'cdn.example.com');
      expect(a.tls.fingerprint, 'chrome');
      expect(a.tls.alpn, ['h2', 'http/1.1']);
      expect(a.tls.insecure, isTrue);
    });

    test('sni default = server, insecure default = false', () {
      final a = parseUri('anytls://pw@h.example:8443') as AnyTlsSpec;
      expect(a.tls.serverName, 'h.example');
      expect(a.tls.insecure, isFalse);
    });
  });

  group('parseAnyTls — idle-поля', () {
    test('idle_session_check_interval / timeout / min_idle_session', () {
      final a = parseUri('anytls://pw@h.example:8443'
          '?idle_session_check_interval=15s'
          '&idle_session_timeout=45s'
          '&min_idle_session=3') as AnyTlsSpec;
      expect(a.idleSessionCheckInterval, '15s');
      expect(a.idleSessionTimeout, '45s');
      expect(a.minIdleSession, 3);
    });

    test('idle-поля отсутствуют → пусто / null', () {
      final a = parseUri('anytls://pw@h.example:8443') as AnyTlsSpec;
      expect(a.idleSessionCheckInterval, '');
      expect(a.idleSessionTimeout, '');
      expect(a.minIdleSession, isNull);
    });

    test('невалидный min_idle_session → null', () {
      final a = parseUri('anytls://pw@h.example?min_idle_session=abc')
          as AnyTlsSpec;
      expect(a.minIdleSession, isNull);
    });
  });

  group('round-trip parseUri(toUri()) ≈ spec', () {
    void roundTrip(String uri) {
      final a = parseUri(uri) as AnyTlsSpec;
      final b = parseUri(a.toUri()) as AnyTlsSpec;
      expect(b.password, a.password);
      expect(b.server, a.server);
      expect(b.port, a.port);
      expect(b.label, a.label);
      expect(b.tls.enabled, a.tls.enabled);
      expect(b.tls.serverName, a.tls.serverName);
      expect(b.tls.alpn, a.tls.alpn);
      expect(b.tls.insecure, a.tls.insecure);
      expect(b.tls.fingerprint, a.tls.fingerprint);
      expect(b.idleSessionCheckInterval, a.idleSessionCheckInterval);
      expect(b.idleSessionTimeout, a.idleSessionTimeout);
      expect(b.minIdleSession, a.minIdleSession);
    }

    test('минимальный', () {
      roundTrip('anytls://secret@h.example:8443#AT');
    });

    test('полный TLS + idle', () {
      roundTrip('anytls://pw@h.example:8443'
          '?sni=cdn.example.com&fp=chrome&alpn=h2&allowInsecure=1'
          '&idle_session_timeout=30s&min_idle_session=2#Full');
    });

    test('IPv6 + спецсимволы в пароле', () {
      roundTrip('anytls://p%40ss@[2001:db8::1]:8443#v6');
    });
  });

  group('emit → sing-box outbound', () {
    test('полный набор полей', () {
      final a = parseUri('anytls://pw@h.example:8443'
          '?sni=cdn.example.com&idle_session_timeout=30s&min_idle_session=2'
          '#Tag1') as AnyTlsSpec;
      final out = a.emit(TemplateVars.empty).map;
      expect(out['type'], 'anytls');
      expect(out['tag'], 'Tag1');
      expect(out['server'], 'h.example');
      expect(out['server_port'], 8443);
      expect(out['password'], 'pw');
      expect((out['tls'] as Map)['enabled'], isTrue);
      expect((out['tls'] as Map)['server_name'], 'cdn.example.com');
      expect(out['idle_session_timeout'], '30s');
      expect(out['min_idle_session'], 2);
    });

    test('tls эмитится всегда (TLS-only), idle опускается пустым', () {
      final a = parseUri('anytls://pw@h.example:8443') as AnyTlsSpec;
      final out = a.emit(TemplateVars.empty).map;
      expect((out['tls'] as Map)['enabled'], isTrue);
      expect(out.containsKey('idle_session_timeout'), isFalse);
      expect(out.containsKey('idle_session_check_interval'), isFalse);
      expect(out.containsKey('min_idle_session'), isFalse);
    });
  });

  group('parseSingboxEntry type=anytls', () {
    test('полный entry', () {
      final spec = parseSingboxEntry({
        'type': 'anytls',
        'tag': 'at-1',
        'server': '10.0.0.1',
        'server_port': 8443,
        'password': 'pw',
        'tls': {'enabled': true, 'server_name': 'cdn.example.com'},
        'idle_session_check_interval': '15s',
        'idle_session_timeout': '45s',
        'min_idle_session': 3,
      });
      expect(spec, isA<AnyTlsSpec>());
      final a = spec as AnyTlsSpec;
      expect(a.tag, 'at-1');
      expect(a.password, 'pw');
      expect(a.tls.serverName, 'cdn.example.com');
      expect(a.idleSessionCheckInterval, '15s');
      expect(a.idleSessionTimeout, '45s');
      expect(a.minIdleSession, 3);
    });

    test('TLS-only: entry без tls → forced enabled', () {
      final a = parseSingboxEntry({
        'type': 'anytls',
        'tag': 'x',
        'server': 'h',
        'server_port': 443,
        'password': 'pw',
      }) as AnyTlsSpec;
      expect(a.tls.enabled, isTrue, reason: 'AnyTLS TLS-only');
      expect(a.tls.serverName, 'h');
    });

    test('без server/port → null', () {
      expect(parseSingboxEntry({'type': 'anytls', 'tag': 'x'}), isNull);
    });

    test('emit → parseSingboxEntry — JSON round-trip', () {
      final a = parseUri('anytls://pw@h.example:8443'
          '?sni=cdn.example.com&idle_session_timeout=30s#T') as AnyTlsSpec;
      final b = parseSingboxEntry(a.emit(TemplateVars.empty).map) as AnyTlsSpec;
      expect(b.password, a.password);
      expect(b.tls.serverName, a.tls.serverName);
      expect(b.idleSessionTimeout, a.idleSessionTimeout);
    });

    test('REALITY из JSON сохраняется через toUri round-trip (§269 ревью)', () {
      // Валидный X25519 pbk (43-char base64url).
      const pbk = 'GLViB2j8AWjB2Ckjr9zFcLxDh2fL0kD-P1gLZ0qL7hQ';
      final j = parseSingboxEntry({
        'type': 'anytls',
        'tag': 'r',
        'server': 'h.example',
        'server_port': 443,
        'password': 'pw',
        'tls': {
          'enabled': true,
          'server_name': 'cdn.example.com',
          'reality': {'enabled': true, 'public_key': pbk, 'short_id': 'abcd'},
        },
      }) as AnyTlsSpec;
      expect(j.tls.reality?.publicKey, pbk);
      // toUri → parse: REALITY не теряется.
      final back = parseUri(j.toUri()) as AnyTlsSpec;
      expect(back.tls.reality?.publicKey, pbk);
      expect(back.tls.reality?.shortId, 'abcd');
    });
  });
}
