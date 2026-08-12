import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/masque_account.dart';

/// §130 — MasqueAccount round-trip + redaction + URI.
void main() {
  MasqueAccount sample() => const MasqueAccount(
        privKeyDer: 'PRIVDER==',
        serverPubDer: 'PUBDER==',
        clientV4: '172.16.0.2/32',
        clientV6: '2606:4700:110::2/128',
        server: '162.159.198.1',
        port: 443,
        deviceId: 'dev123',
        token: 'secret-token',
        createdAt: '2026-07-02T00:00:00Z',
        idleTimeout: '10m',
        keepAlive: '45s',
      );

  test('toJson/fromJson round-trip', () {
    final a = sample();
    final b = MasqueAccount.fromJson(a.toJson().cast<String, dynamic>());
    expect(b, isNotNull);
    expect(b!.privKeyDer, a.privKeyDer);
    expect(b.serverPubDer, a.serverPubDer);
    expect(b.clientV4, a.clientV4);
    expect(b.server, a.server);
    expect(b.port, a.port);
    expect(b.idleTimeout, a.idleTimeout);
    expect(b.keepAlive, a.keepAlive);
  });

  test('fromJson отвергает пустые ключи', () {
    expect(MasqueAccount.fromJson({'priv_key_der': '', 'server_pub_der': 'x'}),
        isNull);
    expect(MasqueAccount.fromJson({'server_pub_der': 'x'}), isNull);
  });

  test('redacted маскирует приватник и токен', () {
    final r = sample().redacted();
    expect(r['priv_key_der'], '<redacted>');
    expect(r['token'], '<redacted>');
    expect(r.containsKey('server_pub_der'), isTrue); // pubkey не секрет
    expect(r['server'], '162.159.198.1');
  });

  test('toMasqueUri содержит все поля', () {
    final uri = sample().toMasqueUri();
    expect(uri, startsWith('masque://'));
    expect(uri, contains('publickey=PUBDER'));
    expect(uri, contains('vhttp=h3'));
    expect(uri, contains('profile=cloudflare'));
    expect(uri, contains('162.159.198.1:443'));
  });

  test('§393 — версия HTTP задаётся при сборке URI, а не хранится в аккаунте',
      () {
    expect(sample().toMasqueUri(vhttp: 'h2'), contains('vhttp=h2'));
    // Ключа network в хранимом JSON больше нет; старая запись с ним читается.
    expect(sample().toJson().containsKey('network'), isFalse);
    final legacy = sample().toJson().cast<String, dynamic>()
      ..['network'] = 'h2';
    expect(MasqueAccount.fromJson(legacy), isNotNull);
  });
}
