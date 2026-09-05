import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/services/warp/warp_client.dart';

/// §418 — перебор хостов API регистрации WARP. HTTP замокан.
///
/// Правила: сетевая ошибка/таймаут на хосте → следующий; любой HTTP-ответ —
/// итог (дальше не идём); хост-победитель держится на весь поток
/// (PATCH enroll / license уходят туда же, куда ушёл POST /reg).
void main() {
  const devices = 'https://api.devices.cloudflare.com';
  const legacy = 'https://api.cloudflareclient.com';

  Map<String, dynamic> regResponse() => {
        'id': 'device-123',
        'token': 'tok-abc',
        'account': {'id': 'acc-456', 'warp_plus': false},
        'config': {
          'client_id': base64.encode([1, 2, 3]),
          'peers': [
            {
              'public_key': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=',
              'endpoint': {'host': 'engage.cloudflareclient.com:2408'},
            },
          ],
          'interface': {
            'addresses': {'v4': '172.16.0.2', 'v6': '2606:4700:110::2'},
          },
        },
      };

  Map<String, dynamic> masqueEnrollResponse() => {
        'config': {
          'peers': [
            {
              'public_key':
                  '-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----\n',
              'endpoint': {
                'v4': '162.159.198.2:0',
                'ports': [443, 500],
              },
            },
          ],
          'interface': {
            'addresses': {'v4': '172.16.0.2', 'v6': ''},
          },
        },
      };

  test('первый хост недоступен → регистрация через второй; license туда же',
      () async {
    final urls = <String>[];
    final client = MockClient((req) async {
      urls.add(req.url.toString());
      if (req.url.host == 'api.devices.cloudflare.com') {
        throw const SocketException('connection timed out');
      }
      if (req.method == 'PATCH') {
        return http.Response(jsonEncode({'warp_plus': true}), 200);
      }
      return http.Response(jsonEncode(regResponse()), 200);
    });

    final acc = await WarpClient(client: client, apiHosts: [devices, legacy])
        .register(nowIso8601: '2026-09-04T00:00:00Z', licenseKey: 'LIC');

    expect(acc.deviceId, 'device-123');
    expect(acc.warpPlus, isTrue);
    expect(urls, [
      '$devices/${WarpApi.version}/reg',
      '$legacy/${WarpApi.version}/reg',
      '$legacy/${WarpApi.version}/reg/device-123/account',
    ]);
  });

  test('таймаут первого хоста → второй', () async {
    final hosts = <String>[];
    final client = MockClient((req) async {
      hosts.add(req.url.host);
      if (req.url.host == 'api.devices.cloudflare.com') {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      return http.Response(jsonEncode(regResponse()), 200);
    });

    final acc = await WarpClient(
      client: client,
      timeout: const Duration(milliseconds: 50),
      apiHosts: [devices, legacy],
    ).register(nowIso8601: '2026-09-04T00:00:00Z');

    expect(acc.deviceId, 'device-123');
    expect(hosts, ['api.devices.cloudflare.com', 'api.cloudflareclient.com']);
  });

  test('все хосты недоступны → WarpException с перечнем хостов', () async {
    final client = MockClient(
        (req) async => throw const SocketException('unreachable'));

    expect(
      () => WarpClient(client: client, apiHosts: [devices, legacy])
          .register(nowIso8601: '2026-09-04T00:00:00Z'),
      throwsA(isA<WarpException>().having(
        (e) => e.message,
        'message',
        allOf(contains('network error'), contains(devices), contains(legacy)),
      )),
    );
  });

  test('HTTP-ошибка первого хоста — итог, второй не пробуем', () async {
    final hosts = <String>[];
    final client = MockClient((req) async {
      hosts.add(req.url.host);
      return http.Response('nope', 429);
    });

    await expectLater(
      WarpClient(client: client, apiHosts: [devices, legacy])
          .register(nowIso8601: '2026-09-04T00:00:00Z'),
      throwsA(isA<WarpException>()),
    );
    expect(hosts, ['api.devices.cloudflare.com']);
  });

  test('первый хост отвечает → второй не трогаем (дефолтный порядок)',
      () async {
    final hosts = <String>[];
    final client = MockClient((req) async {
      hosts.add(req.url.host);
      return http.Response(jsonEncode(regResponse()), 200);
    });

    await WarpClient(client: client, apiHosts: [devices, legacy])
        .register(nowIso8601: '2026-09-04T00:00:00Z');
    expect(hosts, ['api.devices.cloudflare.com']);
  });

  test('без apiHosts и без asset → WarpApi.fallbackHosts, devices первым',
      () async {
    final hosts = <String>[];
    final client = MockClient((req) async {
      hosts.add(req.url.host);
      return http.Response(jsonEncode(regResponse()), 200);
    });

    // В unit-тесте rootBundle недоступен → picker без пула → зашитый список.
    await WarpClient(client: client)
        .register(nowIso8601: '2026-09-04T00:00:00Z');
    expect(hosts, ['api.devices.cloudflare.com']);
    expect(WarpApi.fallbackHosts.first, devices);
    expect(WarpApi.fallbackHosts, contains(legacy));
  });

  test('registerMasque: POST на второй после отказа первого, PATCH туда же; '
      'в POST — 32-байтный ключ', () async {
    final calls = <String>[];
    String? postedKey;
    final client = MockClient((req) async {
      calls.add('${req.method} ${req.url}');
      if (req.url.host == 'api.devices.cloudflare.com') {
        throw const SocketException('connection timed out');
      }
      if (req.method == 'POST') {
        postedKey =
            (jsonDecode(req.body) as Map<String, dynamic>)['key'] as String;
        return http.Response(jsonEncode(regResponse()), 200);
      }
      expect(req.headers['Authorization'], 'Bearer tok-abc');
      return http.Response(jsonEncode(masqueEnrollResponse()), 200);
    });

    final acc = await WarpClient(client: client, apiHosts: [devices, legacy])
        .registerMasque(nowIso8601: '2026-09-04T00:00:00Z');

    expect(acc.deviceId, 'device-123');
    expect(acc.server, '162.159.198.2');
    expect(base64.decode(postedKey!).length, 32);
    expect(calls, [
      'POST $devices/${WarpApi.version}/reg',
      'POST $legacy/${WarpApi.version}/reg',
      'PATCH $legacy/${WarpApi.version}/reg/device-123',
    ]);
  });
}
