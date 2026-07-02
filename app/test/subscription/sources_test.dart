import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/models/subscription_meta.dart';
import 'package:lxbox/services/subscription/sources.dart';

void main() {
  // Нулевые backoff'ы — ретраи без реального сна 1s+3s (см. §101): иначе
  // retry-кейсы спали бы ~4s каждый и flaky'или в параллельном suite.
  setUp(() => fetchBackoffsForTesting = const [Duration.zero, Duration.zero]);
  tearDown(() => fetchBackoffsForTesting = null);

  group('fetchRaw — retry/backoff (night T1-3)', () {
    test('3rd attempt succeeds after 2 transient 500s', () async {
      var attempts = 0;
      final client = MockClient((req) async {
        attempts++;
        if (attempts < 3) return http.Response('boom', 500);
        return http.Response('ok-body', 200);
      });
      final src = UrlSource('http://x.invalid/sub',
          timeout: const Duration(milliseconds: 500));
      final r = await fetchRaw(src, client: client);
      expect(r.body, 'ok-body');
      expect(attempts, 3);
    });

    test('4xx → throws immediately, no retry', () async {
      var attempts = 0;
      final client = MockClient((req) async {
        attempts++;
        return http.Response('gone', 404);
      });
      final src = UrlSource('http://x.invalid/sub',
          timeout: const Duration(milliseconds: 500));
      await expectLater(() => fetchRaw(src, client: client), throwsException);
      expect(attempts, 1, reason: '4xx is permanent — no retry');
    });

    test('все 3 попытки failed → throws', () async {
      var attempts = 0;
      final client = MockClient((req) async {
        attempts++;
        return http.Response('x', 503);
      });
      final src = UrlSource('http://x.invalid/sub',
          timeout: const Duration(milliseconds: 500));
      await expectLater(() => fetchRaw(src, client: client), throwsException);
      expect(attempts, 3);
    });
  });

  group('parseFromSource — offline sources', () {
    test('InlineSource with URI list → nodes parsed', () async {
      const body = 'vless://u1@h1.com:443#A\ntrojan://p@h2.com:443#B\n';
      final r = await parseFromSource(const InlineSource(body));
      expect(r.nodes, hasLength(2));
      expect(r.meta, isNull);
    });

    test('ClipboardSource empty body → empty nodes, no throw', () async {
      final r = await parseFromSource(const ClipboardSource(''));
      expect(r.nodes, isEmpty);
    });

    test('QrSource with single URI → one node', () async {
      final r = await parseFromSource(
        const QrSource('vless://u@h.com:443?type=ws#X'),
      );
      expect(r.nodes, hasLength(1));
    });

    test('InlineSource with base64-wrapped list → nodes parsed', () async {
      const raw =
          'dmxlc3M6Ly91QGguY29tOjQ0MyN4CnRyb2phbjovL3BAaC5jb206NDQzI3kK';
      final r = await parseFromSource(const InlineSource(raw));
      expect(r.nodes, hasLength(2));
    });
  });

  group('§219 — expire в subscription-userinfo', () {
    Future<SubscriptionMeta?> metaFor(String userinfo) async {
      final client = MockClient((req) async => http.Response(
            'vless://u@h.com:443#A',
            200,
            headers: {'subscription-userinfo': userinfo},
          ));
      final r = await parseFromSource(
        UrlSource('http://x.invalid/sub',
            timeout: const Duration(milliseconds: 500)),
        client: client,
      );
      return r.meta;
    }

    test('непарсимый expire → null (не 0 = эпоха 1970)', () async {
      final m = await metaFor('upload=10; download=20; expire=notanumber');
      expect(m?.expireTimestamp, isNull);
      // остальные поля с дефолтом 0 остаются валидными
      expect(m?.uploadBytes, 10);
      expect(m?.downloadBytes, 20);
    });

    test('отсутствие expire → null', () async {
      final m = await metaFor('upload=10; download=20; total=100');
      expect(m?.expireTimestamp, isNull);
    });

    test('валидный expire → сохраняется', () async {
      final m = await metaFor('expire=1893456000');
      expect(m?.expireTimestamp, 1893456000);
    });
  });
}
