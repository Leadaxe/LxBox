import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/tls_spec.dart';
import 'package:lxbox/models/transport_spec.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §320 — ALPN `h2`/`h3` поверх WebSocket/httpupgrade. Оба транспорта в ядре
/// живут только на HTTP/1.1 (`ws.Dialer.Upgrade`, client.go:93): сервер
/// согласует HTTP/2 и апгрейд уже не проходит. Значения — мусор из
/// vless/vmess-шаблонов, снимаем на эмите.
void main() {
  Map<String, dynamic> tlsOf(NodeSpec n) =>
      n.emitRaw(const TemplateVars()).map['tls'] as Map<String, dynamic>;

  group('TlsSpec.alpnFor', () {
    test('ws оставляет только http/1.1', () {
      final (kept, dropped) = TlsSpec.alpnFor(
          const ['h3', 'h2', 'http/1.1'], const WsTransport());
      expect(kept, ['http/1.1']);
      expect(dropped, ['h3', 'h2']);
    });

    test('httpupgrade — то же правило', () {
      final (kept, dropped) =
          TlsSpec.alpnFor(const ['h2'], const HttpUpgradeTransport());
      expect(kept, isEmpty);
      expect(dropped, ['h2']);
    });

    test('grpc/http/xhttp не ограничивают', () {
      for (final t in <TransportSpec>[
        const GrpcTransport(serviceName: 's'),
        const HttpTransport(),
        const XhttpTransport(),
      ]) {
        final (kept, dropped) = TlsSpec.alpnFor(const ['h2', 'http/1.1'], t);
        expect(kept, ['h2', 'http/1.1'], reason: '$t');
        expect(dropped, isEmpty, reason: '$t');
      }
    });

    test('без транспорта (bare TLS) ограничений нет', () {
      final (kept, dropped) = TlsSpec.alpnFor(const ['h2'], null);
      expect(kept, ['h2']);
      expect(dropped, isEmpty);
    });
  });

  group('эмит узла', () {
    test('ws + h3,h2,http/1.1 → только http/1.1 + warning', () {
      final n = parseUri(
        'trojan://humanity@45.130.125.158:443?path=%2Fassignment'
        '&security=tls&alpn=h3%2Ch2%2Chttp%2F1.1&host=www.ignitelimit.com'
        '&type=ws&sni=www.ignitelimit.com#node',
      )!;
      expect(tlsOf(n)['alpn'], ['http/1.1']);
      expect(
        n.warnings.whereType<IncompatibleAlpnWarning>().single,
        const IncompatibleAlpnWarning('ws', ['h3', 'h2']),
      );
    });

    test('ws + только h2 → ключа alpn нет вовсе (ядро подставит своё)', () {
      final n = parseUri(
        'trojan://pw@example.com:443?type=ws&path=%2Fx&security=tls'
        '&alpn=h2&sni=example.com#node',
      )!;
      expect(tlsOf(n).containsKey('alpn'), isFalse);
      expect(n.warnings.whereType<IncompatibleAlpnWarning>(), hasLength(1));
    });

    test('ws + http/1.1 → без изменений, без warning', () {
      final n = parseUri(
        'trojan://pw@example.com:443?type=ws&path=%2Fx&security=tls'
        '&alpn=http%2F1.1&sni=example.com#node',
      )!;
      expect(tlsOf(n)['alpn'], ['http/1.1']);
      expect(n.warnings.whereType<IncompatibleAlpnWarning>(), isEmpty);
    });

    test('grpc + h2 → сохраняется', () {
      final n = parseUri(
        'trojan://pw@example.com:443?type=grpc&serviceName=s&security=tls'
        '&alpn=h2&sni=example.com#node',
      )!;
      expect(tlsOf(n)['alpn'], ['h2']);
      expect(n.warnings.whereType<IncompatibleAlpnWarning>(), isEmpty);
    });

    test('vless ws + h2 фильтруется так же (правило общее)', () {
      final n = parseUri(
        'vless://11111111-2222-3333-4444-555555555555@example.com:443'
        '?type=ws&path=%2Fx&security=tls&alpn=h2%2Chttp%2F1.1'
        '&sni=example.com#node',
      )!;
      expect(tlsOf(n)['alpn'], ['http/1.1']);
      expect(n.warnings.whereType<IncompatibleAlpnWarning>(), hasLength(1));
    });
  });

  group('round-trip не искажается фильтром', () {
    test('TlsSpec.alpn хранит исходный список, toUri его возвращает', () {
      final src = 'trojan://pw@example.com:443?type=ws&path=%2Fx'
          '&security=tls&alpn=h3%2Ch2%2Chttp%2F1.1&sni=example.com#node';
      final n = parseUri(src)! as TrojanSpec;
      // Парсер НЕ режет: иначе вкладка Source и share-ссылка врали бы.
      expect(n.tls.alpn, ['h3', 'h2', 'http/1.1']);
      expect(Uri.parse(n.toUri()).queryParameters['alpn'], 'h3,h2,http/1.1');
    });
  });
}
