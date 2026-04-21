import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/services/subscription/sources.dart';

void main() {
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
}
