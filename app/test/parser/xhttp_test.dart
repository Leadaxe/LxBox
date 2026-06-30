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
      // §127 — расширенные поля тоже не текут в выхлоп при дефолтах.
      expect(m.containsKey('session_placement'), false);
      expect(m.containsKey('x_padding_obfs_mode'), false);
      expect(m.containsKey('sc_max_each_post_bytes'), false);
    });
  });

  // §127 — расширенные клиентские поля SPEC 002 v2: placement/keys/obfs/tuning,
  // парсинг `extra`-JSON, нормализация sc*, golden round-trip.
  group('XHTTP §127 full params', () {
    test('golden: все 15 полей camelCase → snake_case transport (§8.1)', () {
      final t = parseTransport({
        'type': 'xhttp',
        'host': 'www.example.com',
        'path': '/xhttp',
        'mode': 'packet-up',
        'xPaddingBytes': '100-1000',
        'noGRPCHeader': 'true',
        'sessionPlacement': 'header',
        'sessionKey': 'X-Session',
        'seqPlacement': 'query',
        'seqKey': 'x_seq',
        'uplinkDataPlacement': 'header',
        'uplinkDataKey': 'X-Data',
        'uplinkChunkSize': '3000-4000',
        'uplinkHTTPMethod': 'POST',
        'xPaddingObfsMode': 'true',
        'xPaddingKey': 'x_padding',
        'xPaddingHeader': 'X-Padding',
        'xPaddingPlacement': 'header',
        'xPaddingMethod': 'tokenish',
        'scMaxEachPostBytes': '1000000',
        'scMinPostsIntervalMs': '30',
      }) as XhttpTransport;
      final (m, _) = t.toSingbox(TemplateVars.empty);
      expect(m, {
        'type': 'xhttp',
        'host': 'www.example.com',
        'path': '/xhttp',
        'mode': 'packet-up',
        'x_padding_bytes': '100-1000',
        'no_grpc_header': true,
        'session_placement': 'header',
        'session_key': 'X-Session',
        'seq_placement': 'query',
        'seq_key': 'x_seq',
        'uplink_data_placement': 'header',
        'uplink_data_key': 'X-Data',
        'uplink_chunk_size': '3000-4000',
        'uplink_http_method': 'POST',
        'x_padding_obfs_mode': true,
        'x_padding_key': 'x_padding',
        'x_padding_header': 'X-Padding',
        'x_padding_placement': 'header',
        'x_padding_method': 'tokenish',
        'sc_max_each_post_bytes': '1000000',
        'sc_min_posts_interval_ms': '30',
      });
    });

    test('snake_case формы расширенных полей тоже читаются', () {
      final t = parseTransport({
        'type': 'xhttp',
        'session_placement': 'cookie',
        'x_padding_obfs_mode': '1',
        'uplink_http_method': 'GET',
      }) as XhttpTransport;
      expect(t.sessionPlacement, 'cookie');
      expect(t.xPaddingObfsMode, true);
      expect(t.uplinkHttpMethod, 'GET');
    });

    test('extra (URL-encoded JSON) вливается в transport', () {
      // {"scMaxEachPostBytes":"1000000","scMaxConcurrentPosts":100.0,
      //  "scMinPostsIntervalMs":30.0,"xPaddingBytes":"100-1000","noGRPCHeader":false}
      const extra =
          '%7B%22scMaxEachPostBytes%22%3A%221000000%22%2C%22scMaxConcurrentPosts%22'
          '%3A100.0%2C%22scMinPostsIntervalMs%22%3A30.0%2C%22xPaddingBytes%22%3A'
          '%22100-1000%22%2C%22noGRPCHeader%22%3Afalse%7D';
      // Uri.queryParameters сам percent-декодит — эмулируем декодированный extra.
      final decodedExtra = Uri.decodeComponent(extra);
      final t = parseTransport({
        'type': 'xhttp',
        'mode': 'packet-up',
        'extra': decodedExtra,
      }) as XhttpTransport;
      expect(t.xPaddingBytes, '100-1000');
      expect(t.noGrpcHeader, false);
      // числа из extra нормализованы в строку
      expect(t.scMaxEachPostBytes, '1000000');
      expect(t.scMinPostsIntervalMs, '30'); // 30.0 → "30"
      // scMaxConcurrentPosts (legacy) не маппится
      final (m, _) = t.toSingbox(TemplateVars.empty);
      expect(m.containsKey('sc_max_concurrent_posts'), false);
    });

    test('битый extra игнорируется, плоские параметры выживают', () {
      final t = parseTransport({
        'type': 'xhttp',
        'mode': 'packet-up',
        'path': '/p',
        'extra': '{not valid json', // обрезанный
      }) as XhttpTransport;
      expect(t.mode, 'packet-up');
      expect(t.path, '/p');
    });

    test('path с ?-хвостом обрезается', () {
      final t = parseTransport({'type': 'xhttp', 'path': '/GaMeOpTiMiZeR?ed=2048'})
          as XhttpTransport;
      expect(t.path, '/GaMeOpTiMiZeR');
    });

    test('sc* float-хвост отбрасывается (30.0 → "30")', () {
      final t = parseTransport({
        'type': 'xhttp',
        'scMinPostsIntervalMs': '30.0',
        'scMaxEachPostBytes': '1000000',
      }) as XhttpTransport;
      expect(t.scMinPostsIntervalMs, '30');
      expect(t.scMaxEachPostBytes, '1000000');
    });

    test('round-trip: parseTransport(transportToQuery(golden)) ≈ golden', () {
      const golden = XhttpTransport(
        host: 'www.example.com',
        path: '/xhttp',
        mode: 'packet-up',
        xPaddingBytes: '100-1000',
        noGrpcHeader: true,
        sessionPlacement: 'header',
        sessionKey: 'X-Session',
        seqPlacement: 'query',
        seqKey: 'x_seq',
        uplinkDataPlacement: 'header',
        uplinkDataKey: 'X-Data',
        uplinkChunkSize: '3000-4000',
        uplinkHttpMethod: 'POST',
        xPaddingObfsMode: true,
        xPaddingKey: 'x_padding',
        xPaddingHeader: 'X-Padding',
        xPaddingPlacement: 'header',
        xPaddingMethod: 'tokenish',
        scMaxEachPostBytes: '1000000',
        scMinPostsIntervalMs: '30',
      );
      final q = transportToQuery(golden);
      final back = parseTransport(q) as XhttpTransport;
      // сравнение по выхлопу toSingbox (= по смыслу spec)
      expect(back.toSingbox(TemplateVars.empty).$1,
          golden.toSingbox(TemplateVars.empty).$1);
    });

    test('toUri пишет только не-дефолтные поля (§8.3 — без раздувания)', () {
      // дефолтная нода: эти значения == дефолт ядра → НЕ должны попасть в query.
      const x = XhttpTransport(
        path: '/',
        sessionPlacement: '', // дефолт path
        uplinkHttpMethod: '', // дефолт POST
        xPaddingObfsMode: false,
      );
      final q = transportToQuery(x);
      expect(q.containsKey('sessionPlacement'), false);
      expect(q.containsKey('uplinkHTTPMethod'), false);
      expect(q.containsKey('xPaddingObfsMode'), false);
    });
  });
}
