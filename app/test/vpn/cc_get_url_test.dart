import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/platform_channels.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §392 — `CcGetUrlResult` (GetURLViaOutbound, kernel SPEC 058) и проброс
/// параметров вызова через MethodChannel.
///
/// Главный инвариант под тестом: **не-2xx — это результат, а не ошибка**.
/// Единственный признак несостоявшегося обмена — непустой `error`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('§392 — CcGetUrlResult.fromMap', () {
    test('успешный обмен: статус/тело/метаданные', () {
      final r = CcGetUrlResult.fromMap(const {
        'status': 200,
        'content': 'warp=on\nip=1.2.3.4',
        'truncated': false,
        'contentType': 'text/plain',
        'remoteAddr': '104.16.0.1:443',
        'elapsedMs': 312,
        'error': '',
      });
      expect(r.ok, true);
      expect(r.status, 200);
      expect(r.content, contains('warp=on'));
      expect(r.remoteAddr, '104.16.0.1:443');
      expect(r.elapsedMs, 312);
    });

    test('не-2xx — РЕЗУЛЬТАТ, а не ошибка (ok остаётся true)', () {
      final r = CcGetUrlResult.fromMap(const {
        'status': 429,
        'content': '{"error":"rate limit"}',
        'error': '',
      });
      // 429 от гео-сервиса — данные, ради которых проба и существует;
      // помечать узел нерабочим по такому ответу нельзя.
      expect(r.ok, true);
      expect(r.status, 429);
      expect(r.content, isNotEmpty);
    });

    test('несостоявшийся обмен: error непустой → ok=false', () {
      final r = CcGetUrlResult.fromMap(const {
        'error': 'outbound or endpoint not found: node-de',
      });
      expect(r.ok, false);
      expect(r.status, 0);
      expect(r.content, isEmpty);
    });

    test('truncated прокидывается (обрезка не молчаливая)', () {
      final r = CcGetUrlResult.fromMap(
          const {'status': 200, 'content': 'x', 'truncated': true, 'error': ''});
      expect(r.truncated, true);
    });

    test('дефолты при отсутствующих ключах', () {
      final r = CcGetUrlResult.fromMap(const {});
      expect(r.status, 0);
      expect(r.content, isEmpty);
      expect(r.truncated, false);
      expect(r.elapsedMs, 0);
      expect(r.ok, true); // error пуст — обмен формально состоялся
    });

    test('num (double из platform channel) приводится к int', () {
      final r = CcGetUrlResult.fromMap(
          const {'status': 200.0, 'elapsedMs': 42.0, 'error': ''});
      expect(r.status, 200);
      expect(r.elapsedMs, 42);
    });
  });

  group('§392 — проброс параметров в native', () {
    const channel = MethodChannel(PlatformChannels.methods);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('getUrlViaOutbound → ccGetUrlViaOutbound с tag/link/timeout/maxBytes',
        () async {
      late MethodCall seen;
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return {'status': 200, 'content': 'ok', 'error': ''};
      });
      final r = await CcChannel.instance.getUrlViaOutbound(
        '🇩🇪 node-de',
        link: 'https://1.1.1.1/cdn-cgi/trace',
        timeoutMs: 10000,
        maxBytes: 65536,
      );
      expect(seen.method, 'ccGetUrlViaOutbound');
      final args = seen.arguments as Map;
      expect(args['tag'], '🇩🇪 node-de');
      expect(args['link'], 'https://1.1.1.1/cdn-cgi/trace');
      expect(args['timeoutMs'], 10000);
      expect(args['maxBytes'], 65536);
      expect(r.content, 'ok');
    });

    test('probeGetUrl → probeGetUrl (ветка выключенного VPN)', () async {
      late MethodCall seen;
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return {'status': 200, 'content': 'trace', 'error': ''};
      });
      final r = await CcChannel.instance.probeGetUrl(
        'node-de',
        link: 'https://ipinfo.io/json',
        timeoutMs: 10000,
        maxBytes: 65536,
      );
      expect(seen.method, 'probeGetUrl');
      expect((seen.arguments as Map)['tag'], 'node-de');
      expect(r.ok, true);
      expect(r.content, 'trace');
    });

    test('native вернул пусто → результат с дефолтами, без броска', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      final r = await CcChannel.instance
          .getUrlViaOutbound('t', link: 'https://example.org');
      expect(r.status, 0);
      expect(r.content, isEmpty);
    });
  });
}
