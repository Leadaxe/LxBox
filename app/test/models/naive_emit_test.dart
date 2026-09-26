import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/tls_spec.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/parser/uri_utils.dart';

import '../parser/engine_test_setup.dart';
import '../parser/parse_link_as.dart';

void main() {
  // §480 W7 — `toUri()` этой схемы собирает ДВИЖОК по секции реестра, как и
  // её разбор. Без загруженных секций ссылки нет вовсе (критерий 7 спеки:
  // рукописного запасного пути у переехавшей схемы не осталось).
  setUpAll(loadEngineSections);

  group('NaïveProxy emit (spec 037 §4)', () {
    NaiveSpec mk({
      String tag = 'naive-test',
      String label = 'naive-test',
      String server = 'h.example.com',
      int port = 443,
      String username = '',
      String password = '',
      Map<String, String> extraHeaders = const {},
      NodeSpec? chained,
    }) =>
        NaiveSpec(
          id: 'id-1',
          tag: tag,
          label: label,
          server: server,
          port: port,
          rawSource: '',
          username: username,
          password: password,
          tls: TlsSpec(enabled: true, serverName: server),
          extraHeaders: extraHeaders,
          chained: chained,
        );

    test('minimal anonymous outbound', () {
      final entry = mk().emit(TemplateVars.empty);
      final m = entry.map;
      expect(m['type'], 'naive');
      expect(m['tag'], 'naive-test');
      expect(m['server'], 'h.example.com');
      expect(m['server_port'], 443);
      // sing-box NaiveOutboundOptions не имеет поля `network`.
      expect(m.containsKey('network'), false);
      expect(m.containsKey('username'), false);
      expect(m.containsKey('password'), false);
      expect(m.containsKey('extra_headers'), false);
      expect(m.containsKey('detour'), false);
      // TLS обязательно: enabled + server_name = host, без alpn/utls/insecure.
      final tls = m['tls'] as Map;
      expect(tls['enabled'], true);
      expect(tls['server_name'], 'h.example.com');
      expect(tls.containsKey('alpn'), false);
      expect(tls.containsKey('insecure'), false);
      expect(tls.containsKey('utls'), false);
    });

    test('with username + password', () {
      final m = mk(username: 'u', password: 'p').emit(TemplateVars.empty).map;
      expect(m['username'], 'u');
      expect(m['password'], 'p');
    });

    test('with password only — username omitted', () {
      final m = mk(password: 'onlypass').emit(TemplateVars.empty).map;
      expect(m.containsKey('username'), false);
      expect(m['password'], 'onlypass');
    });

    test('extra_headers — sing-box field name + sorted keys', () {
      final m = mk(
        username: 'u',
        password: 'p',
        extraHeaders: const {
          'Z-Last': 'z',
          'A-First': 'a',
          'M-Mid': 'm',
        },
      ).emit(TemplateVars.empty).map;
      // sing-box NaiveOutboundOptions использует `extra_headers`, не `headers`.
      expect(m.containsKey('headers'), false);
      final eh = m['extra_headers'] as Map;
      expect(eh.keys.toList(), ['A-First', 'M-Mid', 'Z-Last']);
      expect(eh['A-First'], 'a');
    });

    test('chained → detour tag in outbound', () {
      final detour = mk(tag: 'jump', server: 'jump.example.com');
      final m = mk(chained: detour).emit(TemplateVars.empty).map;
      expect(m['detour'], 'jump');
    });

    test('protocol getter returns "naive"', () {
      expect(mk().protocol, 'naive');
    });
  });

  group('NaïveProxy toUri (spec 037 §5)', () {
    // §533 / контракт 1.1.53 (§49 п.12) — ПОРТ ПИШЕТСЯ ВСЕГДА. Оверлей
    // `emit.omit_port: 443` снят: реестр порт пишет, и у лаунчера `hostPort`
    // писал его всегда. Ссылка БЕЗ порта по-прежнему читается — дефолт
    // разбора 443 объявлен секцией (кейсы round-trip ниже это держат).
    test('пишет :443 — порт больше не опускается', () {
      final s = NaiveSpec(
        id: 'id', tag: 't', label: 't',
        server: 'h.example.com', port: 443, rawSource: '',
        username: 'u', password: 'p',
        tls: const TlsSpec(enabled: true, serverName: 'h.example.com'),
      );
      expect(s.toUri(), 'naive+https://u:p@h.example.com:443#t');
    });

    test('keeps non-default port', () {
      final s = NaiveSpec(
        id: 'id', tag: 't', label: 't',
        server: 'h', port: 8443, rawSource: '',
        password: 'p',
        tls: const TlsSpec(enabled: true, serverName: 'h'),
      );
      expect(s.toUri(), 'naive+https://p@h:8443#t');
    });

    // §465 — одиночный userinfo читается как password, поэтому форма «только
    // username» обязана нести двоеточие, иначе собственная ссылка вернулась
    // бы с именем в слоте пароля.
    test('username without password → user:@', () {
      final s = NaiveSpec(
        id: 'id', tag: 't', label: 't',
        server: 'h', port: 443, rawSource: '',
        username: 'u',
        tls: const TlsSpec(enabled: true, serverName: 'h'),
      );
      expect(s.toUri(), 'naive+https://u:@h:443#t');
    });

    test('anonymous → no userinfo in URI', () {
      final s = NaiveSpec(
        id: 'id', tag: 't', label: 't',
        server: 'h', port: 443, rawSource: '',
        tls: const TlsSpec(enabled: true, serverName: 'h'),
      );
      expect(s.toUri(), 'naive+https://h:443#t');
    });

    test('serializes extra-headers sorted, CRLF-encoded', () {
      final s = NaiveSpec(
        id: 'id', tag: 't', label: 't',
        server: 'h', port: 443, rawSource: '',
        username: 'u', password: 'p',
        tls: const TlsSpec(enabled: true, serverName: 'h'),
        extraHeaders: const {'B-Two': '2', 'A-One': '1'},
      );
      // Expect: extra-headers=A-One%3A%201%0D%0AB-Two%3A%202
      final uri = s.toUri();
      expect(uri.contains('extra-headers='), true);
      // Lex order: A-One then B-Two.
      expect(
        uri.contains(
          'A-One%3A%201%0D%0AB-Two%3A%202',
        ),
        true,
        reason: 'expected lexicographic CRLF-joined headers, got: $uri',
      );
    });

    test('dropping invalid header name on encode', () {
      // На входе невозможный header — encoder тихо дропает.
      //
      // §480 W7: правило больше не живёт отдельной функцией в коде эмита —
      // годность пары судит ТА ЖЕ регулярка `extract.re`, какой её читает
      // разбор. Напиши эмиттер такую пару, разбор пропустил бы её
      // (`on_item_invalid`), и круг потерял бы её молча.
      final s = NaiveSpec(
        id: 'id', tag: 't', label: 't',
        server: 'h', port: 443, rawSource: '',
        username: 'u', password: 'p',
        tls: const TlsSpec(enabled: true, serverName: 'h'),
        extraHeaders: const {'X Bad': 'v', 'X-Good': 'ok'},
      );
      final uri = s.toUri();
      expect(uri.contains('X-Good%3A%20ok'), true, reason: uri);
      expect(uri.contains('X%20Bad'), false, reason: uri);
    });

  });

  group('NaïveProxy round-trip', () {
    test('parseUri(toUri()) preserves user, pass, host, port, label', () {
      final original = parseLinkAs<NaiveSpec>(
        'naive+https://user:pass@server.example.com:8443?#JP-01',
      )!;
      final s2 = parseUri(original.toUri()) as NaiveSpec;
      expect(s2.username, original.username);
      expect(s2.password, original.password);
      expect(s2.server, original.server);
      expect(s2.port, original.port);
      expect(s2.label, original.label);
    });

    // §465 / контракт §24.2 п. 7.3 — три формы userinfo держат round-trip
    // `parseUri(toUri(spec)) ≈ spec`. Раньше форма «только пароль» после
    // своего же эмита возвращалась именем пользователя.
    test('round-trip preserves password-only auth (no colon)', () {
      final original = parseLinkAs<NaiveSpec>('naive+https://onlypass@host.example.com')!;
      expect(original.username, '');
      expect(original.password, 'onlypass');
      final s2 = parseUri(original.toUri()) as NaiveSpec;
      expect(s2.username, '');
      expect(s2.password, 'onlypass');
    });

    test('round-trip preserves username-only auth (user:)', () {
      final original = parseLinkAs<NaiveSpec>('naive+https://onlyuser:@host.example.com')!;
      expect(original.username, 'onlyuser');
      expect(original.password, '');
      // Вход БЕЗ порта, выход С портом (§49 п.12): дефолт разбора 443
      // подставляется секцией, и круг сходится по ТЕЛУ, а не по строке.
      expect(original.toUri(), 'naive+https://onlyuser:@host.example.com:443');
      final s2 = parseUri(original.toUri()) as NaiveSpec;
      expect(s2.username, 'onlyuser');
      expect(s2.password, '');
    });

    test('round-trip preserves user+pass', () {
      final original = parseLinkAs<NaiveSpec>('naive+https://u:p@host.example.com')!;
      final s2 = parseUri(original.toUri()) as NaiveSpec;
      expect(s2.username, 'u');
      expect(s2.password, 'p');
    });

    test('round-trip preserves extra-headers (sorted)', () {
      final original = parseLinkAs<NaiveSpec>(
        'naive+https://u:p@host?extra-headers=B-Two%3A%202%0D%0AA-One%3A%201',
      )!;
      final s2 = parseUri(original.toUri()) as NaiveSpec;
      expect(s2.extraHeaders, {'A-One': '1', 'B-Two': '2'});
    });

    test('round-trip drops padding (by design)', () {
      final original = parseLinkAs<NaiveSpec>(
        'naive+https://u:p@host:443?padding=true#X',
      )!;
      // toUri() не пишет padding обратно; повторный парсинг — тоже без padding.
      expect(original.toUri().contains('padding'), false);
    });

    test('toUri stable on second round', () {
      final s = parseLinkAs<NaiveSpec>(
        'naive+https://u:p@host:8443?extra-headers=A%3A1%0D%0AB%3A2#L',
      )!;
      final once = s.toUri();
      final twice = parseUri(once)!.toUri();
      expect(twice, once);
    });
  });
}
