import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/transport/config.dart';
import 'package:lxbox/services/debug/transport/server.dart';

/// Integration-тесты крутят реальный [HttpServer.bind] на ephemeral-порту
/// и стучатся curl-like запросами. Покрывают security-guarantees middleware
/// и transport-wire level: что именно видит удалённый клиент.
///
/// Не трогаем handler'ов требующих controllers — их покрывают unit-тесты
/// на serializers + pipeline.
void main() {
  // NB: НЕ вызываем `TestWidgetsFlutterBinding.ensureInitialized()` —
  // оно подставляет HttpOverrides который возвращает mocked 400 на любой
  // реальный HttpClient-запрос, ломая integration-тесты. Debug-модуль
  // чистый Dart, platform-каналы не трогает.

  late int port;

  setUp(() async {
    // Ephemeral port: bind на 0 → OS выдаёт свободный. Читаем через
    // server.port после start. DebugServerConfig требует конкретный port —
    // берём любой из диапазона 40000-45000 и надеемся что свободен.
    port = 40000 + (DateTime.now().microsecondsSinceEpoch % 5000);

    await DebugServer.I.start(
      DebugServerConfig(
        port: port,
        token: 'test-token-abc',
      ),
      DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime(2020),
      ),
    );
  });

  tearDown(() async {
    await DebugServer.I.stop();
  });

  Future<HttpClientResponse> makeRequest(
    String method,
    String path, {
    String? token = 'test-token-abc',
    String? host = '127.0.0.1',
  }) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:$port$path'),
      );
      if (host != null && host != '127.0.0.1') {
        req.headers.set('host', host);
      }
      if (token != null) {
        req.headers.set('authorization', 'Bearer $token');
      }
      return await req.close();
    } finally {
      client.close(force: false);
    }
  }

  Future<Map<String, dynamic>> readJson(HttpClientResponse resp) async {
    final body = await resp.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  group('DebugServer end-to-end', () {
    test('GET /ping без auth → 200 pong:true', () async {
      final resp = await makeRequest('GET', '/ping', token: null);
      expect(resp.statusCode, 200);
      final json = await readJson(resp);
      expect(json['pong'], isTrue);
    });

    test('GET /state без токена → 401 unauthorized', () async {
      final resp = await makeRequest('GET', '/state', token: null);
      expect(resp.statusCode, 401);
      final json = await readJson(resp);
      expect(json['error']['code'], 'unauthorized');
    });

    test('GET /state с неверным токеном → 401', () async {
      final resp = await makeRequest('GET', '/state', token: 'wrong');
      expect(resp.statusCode, 401);
    });

    test('GET /ping с Host: evil.com → 403 invalid_host (anti-rebind)',
        () async {
      final resp = await makeRequest('GET', '/ping', token: null, host: 'evil.com');
      expect(resp.statusCode, 403);
      final json = await readJson(resp);
      expect(json['error']['code'], 'invalid_host');
    });

    test('GET /unknown/path → 404 not_found', () async {
      final resp = await makeRequest('GET', '/unknown-endpoint');
      expect(resp.statusCode, 404);
      final json = await readJson(resp);
      expect(json['error']['code'], 'not_found');
    });

    test('stop() прерывает listen — connect refused после', () async {
      await DebugServer.I.stop();
      expect(DebugServer.I.running, isFalse);
      Object? err;
      try {
        await makeRequest('GET', '/ping', token: null);
      } catch (e) {
        err = e;
      }
      expect(err, isA<SocketException>());
    });
  });

  group('DebugServer.generateToken', () {
    test('даёт 32 hex символа (128 бит)', () {
      final t = DebugServer.generateToken();
      expect(t.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(t), isTrue);
    });

    test('разные токены при последовательных вызовах', () {
      final a = DebugServer.generateToken();
      final b = DebugServer.generateToken();
      expect(a, isNot(b));
    });
  });
}
