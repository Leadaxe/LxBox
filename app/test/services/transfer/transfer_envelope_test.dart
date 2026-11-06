// §622 — конверт передачи (фича 031, P2).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/transfer/transfer_code.dart';
import 'package:lxbox/services/transfer/transfer_envelope.dart';

void main() {
  final key = newTransferKey();
  final plain = utf8.encode('{"app":"lxbox","kind":"backup","storage":{}}');

  Map<String, dynamic> decode(String json) =>
      jsonDecode(json) as Map<String, dynamic>;

  group('transfer envelope', () {
    test('right key opens it', () async {
      final env = await sealTransferEnvelope(plain, key);
      final m = decode(env);
      expect(m['v'], 1);
      expect(base64.decode(m['nonce'] as String), hasLength(12));
      // Шифротекст + 16 байт тега.
      expect(base64.decode(m['ct'] as String), hasLength(plain.length + 16));
      expect(await openTransferEnvelope(env, key), plain);
    });

    test('plaintext is not visible in the envelope', () async {
      final env = await sealTransferEnvelope(plain, key);
      expect(env.contains('lxbox'), isFalse);
    });

    test('foreign key → auth error', () async {
      final env = await sealTransferEnvelope(plain, key);
      await expectLater(openTransferEnvelope(env, newTransferKey()),
          throwsA(isA<TransferEnvelopeAuthException>()));
    });

    test('corrupted ct → auth error', () async {
      final m = decode(await sealTransferEnvelope(plain, key));
      final ct = base64.decode(m['ct'] as String);
      ct[3] ^= 0x01;
      m['ct'] = base64.encode(ct);
      await expectLater(openTransferEnvelope(jsonEncode(m), key),
          throwsA(isA<TransferEnvelopeAuthException>()));
    });

    test('corrupted tag → auth error', () async {
      final m = decode(await sealTransferEnvelope(plain, key));
      final ct = base64.decode(m['ct'] as String);
      ct[ct.length - 1] ^= 0x80;
      m['ct'] = base64.encode(ct);
      await expectLater(openTransferEnvelope(jsonEncode(m), key),
          throwsA(isA<TransferEnvelopeAuthException>()));
    });

    test('corrupted nonce → auth error', () async {
      final m = decode(await sealTransferEnvelope(plain, key));
      final nonce = base64.decode(m['nonce'] as String);
      nonce[0] ^= 0xff;
      m['nonce'] = base64.encode(nonce);
      await expectLater(openTransferEnvelope(jsonEncode(m), key),
          throwsA(isA<TransferEnvelopeAuthException>()));
    });

    test('malformed envelopes → format error', () async {
      final good = decode(await sealTransferEnvelope(plain, key));
      final cases = <String>[
        'not json',
        '[]',
        jsonEncode({...good, 'v': 2}),
        jsonEncode({...good, 'nonce': base64.encode([1, 2, 3])}),
        jsonEncode({...good, 'nonce': '%%%'}),
        jsonEncode({...good, 'ct': base64.encode([1, 2])}),
        jsonEncode({'v': 1}),
      ];
      for (final c in cases) {
        await expectLater(openTransferEnvelope(c, key),
            throwsA(isA<TransferEnvelopeFormatException>()),
            reason: c);
      }
    });

    test('fresh nonce per seal', () async {
      final a = decode(await sealTransferEnvelope(plain, key));
      final b = decode(await sealTransferEnvelope(plain, key));
      expect(a['nonce'], isNot(b['nonce']));
    });
  });
}
