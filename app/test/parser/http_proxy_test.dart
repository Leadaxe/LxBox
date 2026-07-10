import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §222 — HTTP(S) CONNECT proxy: `proxy-http://` / `proxy-https://`.
void main() {
  group('parseHttpProxy — базовый разбор', () {
    test('plain: host/port/label, TLS выключен', () {
      final s = parseUri('proxy-http://10.0.0.1:8080#Corp proxy');
      expect(s, isA<HttpSpec>());
      final h = s as HttpSpec;
      expect(h.server, '10.0.0.1');
      expect(h.port, 8080);
      expect(h.label, 'Corp proxy');
      expect(h.tag, 'Corp proxy');
      expect(h.tls.enabled, isFalse);
      expect(h.protocol, 'http');
    });

    test('дефолтные порты: 80 для proxy-http, 443 для proxy-https', () {
      final plain = parseUri('proxy-http://p.example') as HttpSpec;
      expect(plain.port, 80);
      final secure = parseUri('proxy-https://p.example') as HttpSpec;
      expect(secure.port, 443);
    });

    test('userinfo: user, user:pass, :pass (только пароль)', () {
      final userOnly =
          parseUri('proxy-http://alice@h.example:3128') as HttpSpec;
      expect(userOnly.username, 'alice');
      expect(userOnly.password, '');

      final both =
          parseUri('proxy-http://alice:s3cret@h.example:3128') as HttpSpec;
      expect(both.username, 'alice');
      expect(both.password, 's3cret');

      final passOnly =
          parseUri('proxy-http://:s3cret@h.example:3128') as HttpSpec;
      expect(passOnly.username, '');
      expect(passOnly.password, 's3cret');
    });

    test('percent-encoded userinfo декодируется', () {
      final h = parseUri(
          'proxy-http://user%40dom:p%3Ass@h.example:8080') as HttpSpec;
      expect(h.username, 'user@dom');
      expect(h.password, 'p:ss');
    });

    test('path и headers из query', () {
      final h = parseUri('proxy-http://h.example:8080'
          '?path=%2Ftunnel'
          '&headers=X-Token%3A%20abc%0D%0AUser-Agent%3A%20curl') as HttpSpec;
      expect(h.path, '/tunnel');
      expect(h.headers, {'X-Token': 'abc', 'User-Agent': 'curl'});
    });

    test('IPv6 host', () {
      final h = parseUri('proxy-http://[2001:db8::1]:8080#v6') as HttpSpec;
      expect(h.server, '2001:db8::1');
      expect(h.port, 8080);
    });

    test('без host → null', () {
      expect(parseUri('proxy-http://'), isNull);
    });
  });

  group('§268 — плюс-алиасы proxy+http / proxy+https', () {
    test('proxy+http эквивалентен proxy-http (plain, TLS off)', () {
      final plus = parseUri('proxy+http://alice:pw@h.example:8080#P')
          as HttpSpec;
      final dash = parseUri('proxy-http://alice:pw@h.example:8080#P')
          as HttpSpec;
      expect(plus.server, dash.server);
      expect(plus.port, dash.port);
      expect(plus.username, dash.username);
      expect(plus.password, dash.password);
      expect(plus.tls.enabled, isFalse);
      expect(dash.tls.enabled, isFalse);
    });

    test('proxy+https эквивалентен proxy-https (TLS on)', () {
      final plus = parseUri('proxy+https://alice:pw@h.example:8443'
          '?sni=proxy.corp#S') as HttpSpec;
      final dash = parseUri('proxy-https://alice:pw@h.example:8443'
          '?sni=proxy.corp#S') as HttpSpec;
      expect(plus.tls.enabled, isTrue);
      expect(dash.tls.enabled, isTrue);
      expect(plus.tls.serverName, 'proxy.corp');
      expect(plus.server, dash.server);
      expect(plus.port, dash.port);
    });

    test('дефолтные порты сохраняются для плюс-формы', () {
      expect((parseUri('proxy+http://p.example') as HttpSpec).port, 80);
      expect((parseUri('proxy+https://p.example') as HttpSpec).port, 443);
    });
  });

  group('parseHttpProxy — TLS (proxy-https)', () {
    test('sni/fp/alpn/insecure по trojan-конвенциям', () {
      final h = parseUri('proxy-https://h.example:8443'
          '?sni=proxy.corp&fp=chrome&alpn=h2,http/1.1&allowInsecure=1'
          '#S') as HttpSpec;
      expect(h.tls.enabled, isTrue);
      expect(h.tls.serverName, 'proxy.corp');
      expect(h.tls.fingerprint, 'chrome');
      expect(h.tls.alpn, ['h2', 'http/1.1']);
      expect(h.tls.insecure, isTrue);
      expect(h.warnings.whereType<InsecureTlsWarning>(), isNotEmpty);
    });

    test('sni default = server, insecure default = false', () {
      final h = parseUri('proxy-https://h.example:8443') as HttpSpec;
      expect(h.tls.enabled, isTrue);
      expect(h.tls.serverName, 'h.example');
      expect(h.tls.insecure, isFalse);
      expect(h.warnings, isEmpty);
    });
  });

  group('round-trip parseUri(toUri()) ≈ spec', () {
    void roundTrip(String uri) {
      final a = parseUri(uri) as HttpSpec;
      final b = parseUri(a.toUri()) as HttpSpec;
      expect(b.server, a.server);
      expect(b.port, a.port);
      expect(b.username, a.username);
      expect(b.password, a.password);
      expect(b.path, a.path);
      expect(b.headers, a.headers);
      expect(b.label, a.label);
      expect(b.tls.enabled, a.tls.enabled);
      expect(b.tls.serverName, a.tls.serverName);
      expect(b.tls.alpn, a.tls.alpn);
      expect(b.tls.insecure, a.tls.insecure);
      expect(b.tls.fingerprint, a.tls.fingerprint);
    }

    test('plain минимальный', () {
      roundTrip('proxy-http://10.0.0.1:8080#P');
    });

    test('plain c auth + path + headers', () {
      roundTrip('proxy-http://alice:s3cret@h.example:3128'
          '?path=%2Ft&headers=X-A%3A%201%0D%0AX-B%3A%202#Full');
    });

    test('пароль без юзера', () {
      roundTrip('proxy-http://:onlypass@h.example:3128#P');
    });

    test('https c полным TLS', () {
      roundTrip('proxy-https://h.example:8443'
          '?sni=proxy.corp&fp=chrome&alpn=h2&allowInsecure=1#S');
    });

    test('IPv6', () {
      roundTrip('proxy-http://user@[2001:db8::1]:8080#v6');
    });
  });

  group('emit → sing-box outbound', () {
    test('полный набор полей', () {
      final h = parseUri('proxy-https://alice:pw@h.example:8443'
          '?path=%2Ft&headers=X-A%3A%201&sni=proxy.corp#Tag1') as HttpSpec;
      final out = h.emit(TemplateVars.empty).map;
      expect(out['type'], 'http');
      expect(out['tag'], 'Tag1');
      expect(out['server'], 'h.example');
      expect(out['server_port'], 8443);
      expect(out['username'], 'alice');
      expect(out['password'], 'pw');
      expect(out['path'], '/t');
      expect(out['headers'], {'X-A': '1'});
      expect((out['tls'] as Map)['enabled'], isTrue);
      expect((out['tls'] as Map)['server_name'], 'proxy.corp');
    });

    test('опциональные поля не эмитятся пустыми', () {
      final h = parseUri('proxy-http://h.example:8080#P') as HttpSpec;
      final out = h.emit(TemplateVars.empty).map;
      expect(out.containsKey('username'), isFalse);
      expect(out.containsKey('password'), isFalse);
      expect(out.containsKey('path'), isFalse);
      expect(out.containsKey('headers'), isFalse);
      expect(out.containsKey('tls'), isFalse);
    });
  });

  group('parseSingboxEntry type=http', () {
    test('полный entry, headers-значения string и list', () {
      final spec = parseSingboxEntry({
        'type': 'http',
        'tag': 'corp-http',
        'server': '10.0.0.1',
        'server_port': 3128,
        'username': 'alice',
        'password': 'pw',
        'path': '/t',
        'headers': {
          'X-A': '1',
          'X-B': ['2', 'ignored'],
        },
        'tls': {'enabled': true, 'server_name': 'proxy.corp'},
      });
      expect(spec, isA<HttpSpec>());
      final h = spec as HttpSpec;
      expect(h.tag, 'corp-http');
      expect(h.server, '10.0.0.1');
      expect(h.port, 3128);
      expect(h.username, 'alice');
      expect(h.password, 'pw');
      expect(h.path, '/t');
      expect(h.headers, {'X-A': '1', 'X-B': '2'});
      expect(h.tls.enabled, isTrue);
      expect(h.tls.serverName, 'proxy.corp');
    });

    test('emit → parseSingboxEntry — JSON round-trip', () {
      final a = parseUri('proxy-https://alice:pw@h.example:8443'
          '?path=%2Ft&headers=X-A%3A%201&sni=proxy.corp#T') as HttpSpec;
      final b =
          parseSingboxEntry(a.emit(TemplateVars.empty).map) as HttpSpec;
      expect(b.server, a.server);
      expect(b.port, a.port);
      expect(b.username, a.username);
      expect(b.password, a.password);
      expect(b.path, a.path);
      expect(b.headers, a.headers);
      expect(b.tls.enabled, a.tls.enabled);
      expect(b.tls.serverName, a.tls.serverName);
    });

    test('без server/port → null', () {
      expect(parseSingboxEntry({'type': 'http', 'tag': 'x'}), isNull);
    });
  });
}
