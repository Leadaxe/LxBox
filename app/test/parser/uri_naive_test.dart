import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'parse_link_as.dart';

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
      final spec = parseLinkAs<NaiveSpec>(
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
      final spec = parseLinkAs<NaiveSpec>('naive+https://user:pass@host.example.com');
      expect(spec, isNotNull);
      expect(spec!.port, 443);
    });

    test('custom port preserved', () {
      final spec = parseLinkAs<NaiveSpec>('naive+https://server.example.com:8443');
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
      final spec = parseLinkAs<NaiveSpec>('naive+https://onlypass@server.example.com');
      expect(spec, isNotNull);
      expect(spec!.username, '');
      expect(spec.password, 'onlypass');
    });

    // Двоеточие и отличает «только имя» от «только пароль».
    test('username-only userinfo keeps the colon (user:)', () {
      final spec = parseLinkAs<NaiveSpec>('naive+https://onlyuser:@server.example.com');
      expect(spec, isNotNull);
      expect(spec!.username, 'onlyuser');
      expect(spec.password, '');
    });

    test('anonymous (no userinfo)', () {
      final spec = parseLinkAs<NaiveSpec>('naive+https://server.example.com:443');
      expect(spec, isNotNull);
      expect(spec!.username, '');
      expect(spec.password, '');
    });

    test('extra-headers parsed and exposed in map', () {
      final spec = parseLinkAs<NaiveSpec>(
        'naive+https://u:p@host?extra-headers=X-User%3Aalice%0D%0AX-Token%3Axyz',
      );
      expect(spec, isNotNull);
      expect(spec!.extraHeaders, {'X-User': 'alice', 'X-Token': 'xyz'});
    });

    test('extra-headers with values containing spaces and colons in value', () {
      // RFC: split по первому `:`. Значение может содержать `:`.
      final spec = parseLinkAs<NaiveSpec>(
        'naive+https://u:p@host?extra-headers=X-Trace%3A%20id%3A123',
      );
      expect(spec!.extraHeaders, {'X-Trace': 'id:123'});
    });

    test('unknown query keys ignored, not failing', () {
      final spec = parseLinkAs<NaiveSpec>(
        'naive+https://u:p@host?unknown=42&also_unknown=foo',
      );
      expect(spec, isNotNull);
      expect(spec!.username, 'u');
      expect(spec.password, 'p');
    });

    test('UTF-8 fragment decoded', () {
      final spec = parseLinkAs<NaiveSpec>(
        'naive+https://u:p@host:443?#%E2%9C%85%20DE',
      );
      expect(spec!.label, '✅ DE');
    });

    test('parseUri rejects bare naive:// (без +https)', () {
      expect(parseUri('naive://u:p@host:443'), isNull);
    });

    test('IPv6 host', () {
      final spec = parseLinkAs<NaiveSpec>('naive+https://u:p@[2001:db8::1]:8443');
      expect(spec, isNotNull);
      expect(spec!.server, '2001:db8::1');
      expect(spec.port, 8443);
    });
  });

  group('D-105 naive_extra_headers_invalid', () {
    test('валидные пары → warning нет', () {
      final spec = parseLinkAs<NaiveSpec>(
        'naive+https://u:p@host?extra-headers=X-User%3Aalice%0D%0AX-Token%3Axyz',
      );
      expect(_extraHeaderWarnings(spec!), isEmpty);
    });

    test('две отброшенные пары → ОДИН warning, с первой парой', () {
      // "no-colon" (нет `:`) и "X User" (пробел в имени); X-Good цел.
      final spec = parseLinkAs<NaiveSpec>(
        'naive+https://u:p@host?extra-headers=no-colon%0D%0AX%20User%3Abad%0D%0AX-Good%3Aok',
      );
      expect(spec!.extraHeaders, {'X-Good': 'ok'});
      expect(_extraHeaderWarnings(spec).single.value, 'no-colon');
    });
  });

  // §566 — рукописный разбор `extra-headers` снят вместе с обёрткой: пары
  // отсеивает правило реестра (`extract` + `on_item_invalid`), его
  // проверяют кейсы группы D-105 выше.
}
