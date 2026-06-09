import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/transport_spec.dart';
import 'package:lxbox/services/parser/transport.dart';

/// §097 — XHTTP (Xray splithttp) нативный transport. По образцу
/// singbox-launcher SPEC 071: parse (URI camelCase + snake) → emit → round-trip,
/// httpupgrade остаётся отдельным типом.
void main() {
  group('XHTTP', () {
    test('parseTransport xhttp → все поля (Xray camelCase)', () {
      final t = parseTransport({
        'type': 'xhttp',
        'mode': 'stream-one',
        'path': '/x',
        'host': 'h',
        'xPaddingBytes': '100-1000',
        'noGRPCHeader': 'true',
      }) as XhttpTransport;
      expect(t.mode, 'stream-one');
      expect(t.path, '/x');
      expect(t.host, 'h');
      expect(t.xPaddingBytes, '100-1000');
      expect(t.noGrpcHeader, true);
    });

    test('snake-case ключи (sing-box) тоже читаются', () {
      final t = parseTransport({
        'type': 'xhttp',
        'x_padding_bytes': '50-200',
        'no_grpc_header': '1',
      }) as XhttpTransport;
      expect(t.xPaddingBytes, '50-200');
      expect(t.noGrpcHeader, true);
    });

    test('toSingbox → нативный type:xhttp + поля, без fallback-warning', () {
      final (m, w) = const XhttpTransport(
        path: '/x',
        host: 'h',
        mode: 'auto',
        xPaddingBytes: '100-1000',
        noGrpcHeader: true,
        headers: {'User-Agent': 'x'},
      ).toSingbox(TemplateVars.empty);
      expect(m['type'], 'xhttp');
      expect(m['path'], '/x');
      expect(m['host'], 'h');
      expect(m['mode'], 'auto');
      expect(m['x_padding_bytes'], '100-1000');
      expect(m['no_grpc_header'], true);
      expect(m['headers'], {'User-Agent': 'x'});
      expect(w, isEmpty);
    });

    test('round-trip transportToQuery → parseTransport', () {
      const x = XhttpTransport(
        path: '/x',
        host: 'h',
        mode: 'packet-up',
        xPaddingBytes: '100-1000',
        noGrpcHeader: true,
      );
      final q = transportToQuery(x);
      expect(q['type'], 'xhttp');
      final t = parseTransport(q) as XhttpTransport;
      expect(t.path, '/x');
      expect(t.host, 'h');
      expect(t.mode, 'packet-up');
      expect(t.xPaddingBytes, '100-1000');
      expect(t.noGrpcHeader, true);
    });

    test('httpupgrade остаётся отдельным типом (регресс на путаницу)', () {
      final t =
          parseTransport({'type': 'httpupgrade', 'path': '/u', 'host': 'h'});
      expect(t, isA<HttpUpgradeTransport>());
      expect(transportToQuery(t!)['type'], 'httpupgrade');
    });

    test('mode-матрица парсится дословно', () {
      for (final mode in ['auto', 'packet-up', 'stream-up', 'stream-one']) {
        final t =
            parseTransport({'type': 'xhttp', 'mode': mode}) as XhttpTransport;
        expect(t.mode, mode);
      }
    });

    test('минимальный xhttp (только type) → дефолты, без лишних ключей', () {
      final (m, _) =
          (parseTransport({'type': 'xhttp'}) as XhttpTransport)
              .toSingbox(TemplateVars.empty);
      expect(m['type'], 'xhttp');
      expect(m.containsKey('mode'), false);
      expect(m.containsKey('x_padding_bytes'), false);
      expect(m.containsKey('no_grpc_header'), false);
    });
  });
}
