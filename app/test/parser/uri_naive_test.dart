import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// Отброшенные пары `extra-headers` на узле: текст кода живёт в реестре
/// (`warnings.json`), предупреждение — обычный [RegistryWarning].
List<RegistryWarning> _extraHeaderWarnings(NodeSpec n) => n.warnings
    .whereType<RegistryWarning>()
    .where((w) => w.code == 'naive_extra_headers_invalid')
    .toList();

void main() {
  // §480 W4 — схема переехала на ДВИЖОК СЕКЦИЙ, и рукописного запасного пути
  // у неё больше нет: без реестра (общие блоки `tls#uri`, `dialer#uri`) и без
  // самих секций разбор не работает вовсе. Гейта здесь НЕТ намеренно: зеркало
  // `assets/contract` лежит в репозитории и едет в APK, и его отсутствие —
  // поломка сборки, а не повод молча пропустить тест.
  setUpAll(() async {
    await ContractRegistry.I.loadFromDirectory('assets/contract');
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
  });

  group('NaïveProxy URI parser (spec 037)', () {
    test('canonical with user+pass+port+label', () {
      final spec = parseNaive(
        'naive+https://user:pass@server.example.com:443/?padding=false#JP-01',
      );
      expect(spec, isNotNull);
      expect(spec!.username, 'user');
      expect(spec.password, 'pass');
      expect(spec.server, 'server.example.com');
      expect(spec.port, 443);
      expect(spec.label, 'JP-01');
      expect(spec.tag, 'JP-01');
      expect(spec.tls.enabled, true);
      expect(spec.tls.serverName, 'server.example.com');
      // naive не принимает alpn/insecure/utls/reality в TLS-блоке.
      expect(spec.tls.alpn, isEmpty);
      expect(spec.tls.insecure, false);
      expect(spec.tls.fingerprint, isNull);
      expect(spec.tls.reality, isNull);
    });

    test('default port 443 when omitted', () {
      final spec = parseNaive('naive+https://user:pass@host.example.com');
      expect(spec, isNotNull);
      expect(spec!.port, 443);
    });

    test('custom port preserved', () {
      final spec = parseNaive('naive+https://server.example.com:8443');
      expect(spec, isNotNull);
      expect(spec!.port, 8443);
      expect(spec.username, '');
      expect(spec.password, '');
    });

    // §465 / контракт §24.2 п. 7.3 — одиночный userinfo это PASSWORD.
    // Прежнее правило (SPEC 103 п. 6, зеркало Go: текст без `:` = username)
    // отменено обеими сторонами: оно расходилось с эмиттерами, которые пишут
    // пароль в user-слот (DuckSoft/hysteria2), и узел не авторизовался.
    test('password-only userinfo (no colon)', () {
      final spec = parseNaive('naive+https://onlypass@server.example.com');
      expect(spec, isNotNull);
      expect(spec!.username, '');
      expect(spec.password, 'onlypass');
    });

    // Двоеточие и отличает «только имя» от «только пароль».
    test('username-only userinfo keeps the colon (user:)', () {
      final spec = parseNaive('naive+https://onlyuser:@server.example.com');
      expect(spec, isNotNull);
      expect(spec!.username, 'onlyuser');
      expect(spec.password, '');
    });

    test('anonymous (no userinfo)', () {
      final spec = parseNaive('naive+https://server.example.com:443');
      expect(spec, isNotNull);
      expect(spec!.username, '');
      expect(spec.password, '');
    });

    test('extra-headers parsed and exposed in map', () {
      final spec = parseNaive(
        'naive+https://u:p@host?extra-headers=X-User%3Aalice%0D%0AX-Token%3Axyz',
      );
      expect(spec, isNotNull);
      expect(spec!.extraHeaders, {'X-User': 'alice', 'X-Token': 'xyz'});
    });

    test('extra-headers with values containing spaces and colons in value', () {
      // RFC: split по первому `:`. Значение может содержать `:`.
      final spec = parseNaive(
        'naive+https://u:p@host?extra-headers=X-Trace%3A%20id%3A123',
      );
      expect(spec!.extraHeaders, {'X-Trace': 'id:123'});
    });

    test('extra-headers with invalid header name dropped', () {
      // "X User" — пробел не в charset — drop, остальные сохраняются.
      final spec = parseNaive(
        'naive+https://u:p@host?extra-headers=X%20User%3Abad%0D%0AX-Good%3Aok',
      );
      expect(spec!.extraHeaders, {'X-Good': 'ok'});
      // D-105 — отброшенная пара видна на узле кодом naive_extra_headers_invalid.
      final w = _extraHeaderWarnings(spec).single;
      expect(w.value, 'X User:bad');
      expect(w.params['entry'], 'X User:bad');
    });

    test('padding query is silently ignored (no field set)', () {
      final spec = parseNaive(
        'naive+https://u:p@host:443?padding=true',
      );
      expect(spec, isNotNull);
      // padding не имеет поля в нашем NaiveSpec — просто игнорим.
      expect(spec!.extraHeaders, isEmpty);
    });

    test('unknown query keys ignored, not failing', () {
      final spec = parseNaive(
        'naive+https://u:p@host?unknown=42&also_unknown=foo',
      );
      expect(spec, isNotNull);
      expect(spec!.username, 'u');
      expect(spec.password, 'p');
    });

    test('UTF-8 fragment decoded', () {
      final spec = parseNaive(
        'naive+https://u:p@host:443?#%E2%9C%85%20DE',
      );
      expect(spec!.label, '✅ DE');
    });

    test('empty host rejects the node (contract §24.6)', () {
      // §463 — узел с пустым host отбраковывается.
      //
      // Прежняя посылка (Go проверяет непустой hostname только у
      // vless/trojan/ssh/tuic/anytls, а naive в список не входит) оказалась
      // неверной: ядро на пустом адресе валит ВЕСЬ конфиг («invalid server
      // address», `sing-box check` на 1.14.0-lx.39), то есть один такой узел
      // из подписки оставлял человека без VPN целиком. Корпус
      // (contract/corpus/uri/naive/empty_host_rejected) нормирует отбраковку
      // с W2c лаунчера.
      expect(parseNaive('naive+https://'), isNull);
    });

    test('dispatcher handles naive+https via parseUri', () {
      final spec = parseUri(
        'naive+https://u:p@server.example.com:443#test',
      );
      expect(spec, isA<NaiveSpec>());
    });

    test('parseUri rejects bare naive:// (без +https)', () {
      expect(parseUri('naive://u:p@host:443'), isNull);
    });

    test('IPv6 host', () {
      final spec = parseNaive('naive+https://u:p@[2001:db8::1]:8443');
      expect(spec, isNotNull);
      expect(spec!.server, '2001:db8::1');
      expect(spec.port, 8443);
    });
  });

  group('D-105 naive_extra_headers_invalid', () {
    test('валидные пары → warning нет', () {
      final spec = parseNaive(
        'naive+https://u:p@host?extra-headers=X-User%3Aalice%0D%0AX-Token%3Axyz',
      );
      expect(_extraHeaderWarnings(spec!), isEmpty);
    });

    test('две отброшенные пары → ОДИН warning, с первой парой', () {
      // "no-colon" (нет `:`) и "X User" (пробел в имени); X-Good цел.
      final spec = parseNaive(
        'naive+https://u:p@host?extra-headers=no-colon%0D%0AX%20User%3Abad%0D%0AX-Good%3Aok',
      );
      expect(spec!.extraHeaders, {'X-Good': 'ok'});
      expect(_extraHeaderWarnings(spec).single.value, 'no-colon');
    });

    test('helper без аккумулятора — молча (http/https headers)', () {
      expect(parseNaiveExtraHeaders('X User: bad\r\nX-Good: ok'),
          {'X-Good': 'ok'});
    });
  });

  group('parseNaiveExtraHeaders helper', () {
    test('empty input → empty map', () {
      expect(parseNaiveExtraHeaders(''), isEmpty);
    });

    test('multi-line CRLF split', () {
      expect(
        parseNaiveExtraHeaders('A: 1\r\nB: 2\r\nC: 3'),
        {'A': '1', 'B': '2', 'C': '3'},
      );
    });

    test('skips lines without colon', () {
      expect(
        parseNaiveExtraHeaders('valid: yes\r\nnocolon\r\nB: ok'),
        {'valid': 'yes', 'B': 'ok'},
      );
    });

    test('trims whitespace around name and value', () {
      expect(
        parseNaiveExtraHeaders('   X-Foo  :   bar   '),
        {'X-Foo': 'bar'},
      );
    });
  });
}
