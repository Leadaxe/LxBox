import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/impair.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/debug/transport/server.dart';
import 'package:lxbox/vpn/platform_channels.dart';

/// §762 — `/impair/*`: маршруты, разбор тела, коды ошибок ядра, 409 без
/// клиента. Нативная часть — заглушка `MethodChannel`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(PlatformChannels.methods);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];
  const status = '{"tag":"node-a","link_params":{"profile":"metro"},'
      '"counters":{},"sublinks":[],"schedule":{"entries":0}}';

  void answer(Future<Object?> Function(MethodCall) f) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return f(call);
    });
  }

  setUp(() {
    calls.clear();
    answer((_) async => status);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  final now = DateTime.utc(2026, 11, 26, 12);
  DebugContext ctx() => DebugContext(
      registry: DebugRegistry.I, appStartedAt: now, clock: () => now);

  DebugRequest req(String method, String path, [String? body]) => DebugRequest(
        method: method,
        uri: Uri.parse('http://127.0.0.1:9269$path'),
        headers: const {},
        body: body == null
            ? Uint8List(0)
            : Uint8List.fromList(utf8.encode(body)),
        receivedAt: now,
      );

  Future<JsonResponse> call(String method, String path, [String? body]) async =>
      await impairHandler(req(method, path, body), ctx()) as JsonResponse;

  Future<DebugError> err(String method, String path, [String? body]) async {
    try {
      await impairHandler(req(method, path, body), ctx());
    } on DebugError catch (e) {
      return e;
    }
    fail('expected DebugError for $method $path');
  }

  test('маршрут смонтирован', () {
    expect(buildDebugRouter().resolve('/impair/x/set'), isNotNull);
  });

  test('GET /impair/{tag} — статус ядра как есть', () async {
    final r = await call('GET', '/impair/node-a');
    expect(r.status, 200);
    expect((r.body as Map)['link_params'], {'profile': 'metro'});
    expect(calls.single.method, 'ccGetImpairStatus');
    expect(calls.single.arguments, {'tag': 'node-a'});
  });

  test('тег с эмодзи URL-encoded доходит раскодированным', () async {
    await call('GET', '/impair/${Uri.encodeComponent('🇩🇪 de/1')}');
    expect((calls.single.arguments as Map)['tag'], '🇩🇪 de/1');
  });

  test('POST set — тело уходит в ядро компактным JSON', () async {
    const body = '{"link_params": {"outage": true, "reset": true}}';
    final r = await call('POST', '/impair/node-a/set', body);
    expect(r.status, 200);
    expect(calls.single.method, 'ccSetImpair');
    expect(calls.single.arguments, {
      'tag': 'node-a',
      'entry': '{"link_params":{"outage":true,"reset":true}}',
    });
  });

  test('POST set — не объект, пустое тело и {} → 400', () async {
    for (final b in [null, '{}', '[1]', '"x"', '{bad']) {
      final e = await err('POST', '/impair/node-a/set', b);
      expect(e, isA<BadRequest>(), reason: 'body $b');
    }
    expect(calls, isEmpty);
  });

  test('POST schedule — entries строкой, start/repeat', () async {
    await call('POST', '/impair/node-a/schedule', jsonEncode({
      'entries': [
        {'at': '0s', 'link_params': {'outage': false}},
        {'at': '80s', 'link_params': {'outage': true}},
      ],
      'start': 'now',
      'repeat': '2m',
    }));
    final a = calls.single.arguments as Map;
    expect(calls.single.method, 'ccScheduleImpair');
    expect(a['tag'], 'node-a');
    expect(jsonDecode(a['entries'] as String), hasLength(2));
    expect(a['start'], 'now');
    expect(a['repeat'], '2m');
  });

  test('POST schedule — entries: [] уходит как "[]", start/repeat пустые',
      () async {
    await call('POST', '/impair/node-a/schedule', '{"entries": []}');
    expect(calls.single.arguments,
        {'tag': 'node-a', 'entries': '[]', 'start': '', 'repeat': ''});
  });

  test('POST schedule — без entries, не список, не строка → 400', () async {
    for (final b in [
      '{}',
      '{"entries": {}}',
      '[]',
      '{"entries": [], "start": 1}',
      '{"entries": [], "repeat": 60}',
      '{"entries": [], "start": "later"}',
    ]) {
      final e = await err('POST', '/impair/node-a/schedule', b);
      expect(e, isA<BadRequest>(), reason: 'body $b');
    }
    expect(calls, isEmpty);
  });

  test('чужой метод → 400, лишний сегмент и пустой тег → 404', () async {
    expect(await err('POST', '/impair/node-a'), isA<BadRequest>());
    expect(await err('GET', '/impair/node-a/set'), isA<BadRequest>());
    expect(await err('GET', '/impair/node-a/x'), isA<NotFound>());
    expect(await err('GET', '/impair/a/set/x'), isA<NotFound>());
    expect(await err('GET', '/impair'), isA<NotFound>());
  });

  test('клиент недоступен (null) → 409', () async {
    answer((_) async => null);
    expect(await err('GET', '/impair/node-a'), isA<Conflict>());
  });

  test('нативного метода нет → 409', () async {
    messenger.setMockMethodCallHandler(channel, null);
    expect(await err('GET', '/impair/node-a'), isA<Conflict>());
  });

  test('коды ядра → статус HTTP, текст ядра в message', () async {
    const cases = {
      'not_found': 404,
      'invalid_argument': 400,
      'failed_precondition': 409,
      'unimplemented': 501,
      'error': 502,
    };
    for (final c in cases.entries) {
      answer((_) async => throw PlatformException(
          code: c.key, message: 'rpc error: code = X desc = ${c.key}'));
      final e = await err('POST', '/impair/node-a/set', '{"sublinks": false}');
      expect(e.status, c.value, reason: c.key);
      expect(e.message, contains(c.key));
    }
  });

  test('статус не объект → 502', () async {
    answer((_) async => '[1]');
    expect((await err('GET', '/impair/node-a')).status, 502);
  });
}
