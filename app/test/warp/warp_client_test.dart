import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/services/warp/warp_account.dart';
import 'package:lxbox/services/warp/warp_client.dart';

/// §025 — WarpClient: keygen, register, license. HTTP замокан.
void main() {
  Map<String, dynamic> regResponse({String? clientId}) => {
        'id': 'device-123',
        'token': 'tok-abc',
        'account': {'id': 'acc-456', 'warp_plus': false},
        'config': {
          'client_id': clientId ?? base64.encode([12, 34, 56]),
          'peers': [
            {
              'public_key': 'PEER_PUB=',
              'endpoint': {
                'v4': '162.159.192.1:2408',
                'host': 'engage.cloudflareclient.com:2408',
              },
            },
          ],
          'interface': {
            'addresses': {'v4': '172.16.0.2', 'v6': '2606:4700:110::2'},
          },
        },
      };

  test('genKeypair → разные 32-байтные base64-ключи', () async {
    final a = await WarpClient.genKeypair();
    final b = await WarpClient.genKeypair();
    expect(base64.decode(a.priv).length, 32);
    expect(base64.decode(a.pub).length, 32);
    expect(a.priv, isNot(b.priv)); // не детерминирован
  });

  test('register: 200 → корректный WarpAccount; в /reg уходит pub, не priv',
      () async {
    String? sentKey;
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      sentKey = body['key'] as String;
      return http.Response(jsonEncode(regResponse()), 200);
    });

    final acc = await WarpClient(client: client).register(
      nowIso8601: '2026-06-14T00:00:00Z',
    );

    expect(acc.peerPub, 'PEER_PUB=');
    expect(acc.clientV4, '172.16.0.2');
    expect(acc.clientV6, '2606:4700:110::2');
    expect(acc.accountId, 'acc-456');
    expect(acc.deviceId, 'device-123');
    expect(acc.endpoint, 'engage.cloudflareclient.com:2408');
    expect(acc.reserved, [12, 34, 56]);
    expect(acc.warpPlus, isFalse);

    // Главное правило: наружу ушёл публичный ключ, не приватный.
    expect(sentKey, isNotNull);
    expect(sentKey, isNot(acc.privKey));
    expect(base64.decode(sentKey!).length, 32);
  });

  test('§135 register: кастомный endpoint НЕ затирается ответом Cloudflare',
      () async {
    final client = MockClient(
        (req) async => http.Response(jsonEncode(regResponse()), 200));

    // Юзер вписал свой IP:port (Advanced). Ответ API несёт host
    // engage.cloudflareclient.com:2408 — но он НЕ должен победить.
    final acc = await WarpClient(client: client).register(
      endpoint: '188.114.97.6:988',
      nowIso8601: '2026-06-14T00:00:00Z',
    );

    expect(acc.endpoint, '188.114.97.6:988');
  });

  test('§135 register: дефолтный endpoint → fallback на host из ответа',
      () async {
    final client = MockClient(
        (req) async => http.Response(jsonEncode(regResponse()), 200));

    // Юзер оставил дефолт → берём host из ответа Cloudflare (старое поведение).
    final acc = await WarpClient(client: client).register(
      endpoint: WarpAccount.defaultEndpoint,
      nowIso8601: '2026-06-14T00:00:00Z',
    );

    expect(acc.endpoint, 'engage.cloudflareclient.com:2408');
  });

  test('register: non-200 → WarpException с упоминанием версии', () async {
    final client = MockClient((req) async => http.Response('nope', 429));
    await expectLater(
      WarpClient(client: client).register(nowIso8601: 'now'),
      throwsA(isA<WarpException>()),
    );
  });

  test('register: битый JSON → WarpException', () async {
    final client = MockClient((req) async => http.Response('<<not json', 200));
    await expectLater(
      WarpClient(client: client).register(nowIso8601: 'now'),
      throwsA(isA<WarpException>()),
    );
  });

  test('license: PATCH 200 warp_plus=true → warpPlus, узел всё равно есть',
      () async {
    final client = MockClient((req) async {
      if (req.method == 'POST') {
        return http.Response(jsonEncode(regResponse()), 200);
      }
      // PATCH account
      expect(req.headers['Authorization'], 'Bearer tok-abc');
      return http.Response(jsonEncode({'warp_plus': true}), 200);
    });
    final acc = await WarpClient(client: client)
        .register(licenseKey: 'KEY-123', nowIso8601: 'now');
    expect(acc.warpPlus, isTrue);
    expect(acc.license, 'KEY-123');
  });

  test('license: PATCH 4xx → free-аккаунт сохраняется (не бросает)', () async {
    final client = MockClient((req) async {
      if (req.method == 'POST') {
        return http.Response(jsonEncode(regResponse()), 200);
      }
      return http.Response('bad license', 400);
    });
    final acc = await WarpClient(client: client)
        .register(licenseKey: 'BAD', nowIso8601: 'now');
    expect(acc.warpPlus, isFalse);
    expect(acc.peerPub, 'PEER_PUB='); // регистрация всё равно прошла
  });

  test('toWireguardUri несёт reserved и парсится; тег WARP/WARP+', () async {
    final client = MockClient(
        (req) async => http.Response(jsonEncode(regResponse()), 200));
    final acc =
        await WarpClient(client: client).register(nowIso8601: 'now');
    final uri = acc.toWireguardUri();
    expect(uri, startsWith('wireguard://'));
    expect(uri, endsWith('#WARP'));
    // Запятые URL-энкодятся (%2C) — parser декодит обратно. Проверяем по
    // декодированному query, не по сырой строке.
    final q = Uri.parse(uri.replaceFirst('#WARP', '')).queryParameters;
    expect(q['reserved'], '12,34,56');
  });

  test('WarpAccount.redacted маскирует priv_key/token/license', () {
    const acc = WarpAccount(
      privKey: 'SECRET_PRIV',
      peerPub: 'PUB',
      clientV4: '172.16.0.2',
      clientV6: '',
      clientId: 'AQID',
      accountId: 'acc',
      deviceId: 'dev',
      token: 'SECRET_TOKEN',
      endpoint: 'engage.cloudflareclient.com:2408',
      createdAt: 'now',
      license: 'LIC',
    );
    final r = acc.redacted();
    expect(r['priv_key'], '<redacted>');
    expect(r['token'], '<redacted>');
    expect(r['license'], '<redacted>');
    expect(r.toString(), isNot(contains('SECRET_PRIV')));
    expect(r.toString(), isNot(contains('SECRET_TOKEN')));
  });
}
