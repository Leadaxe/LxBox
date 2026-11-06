// §622 — код передачи (фича 031, «Код передачи»; P9 — маскирование ключа).

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/transfer/transfer_code.dart';

void main() {
  final key = List<int>.generate(32, (i) => i * 7 % 256);

  TransferCode sample({String name = 'Living room TV'}) => TransferCode(
        addresses: const [
          TransferEndpoint('192.168.1.20', 41234),
          TransferEndpoint('10.0.0.5', 41234),
        ],
        key: key,
        name: name,
      );

  group('TransferCode', () {
    test('encode → tryParse round trip', () {
      final text = sample().encode();
      expect(text, startsWith('lxbox-transfer:1?a=192.168.1.20:41234,10.0.0.5:41234&k='));
      final back = TransferCode.tryParse(text)!;
      expect(back.addresses, sample().addresses);
      expect(back.key, key);
      expect(back.name, 'Living room TV');
    });

    test('key is base64url without padding', () {
      final k = encodeTransferKey(key);
      expect(k.contains('='), isFalse);
      expect(k.contains('+') || k.contains('/'), isFalse);
      expect(decodeTransferKey(k), key);
    });

    test('name with reserved characters survives', () {
      final text = sample(name: 'TV & co=1 +x').encode();
      expect(TransferCode.tryParse(text)!.name, 'TV & co=1 +x');
    });

    test('foreign scheme → null', () {
      expect(TransferCode.tryParse('vless://abc@host:443'), isNull);
      expect(TransferCode.tryParse('https://example.com/?a=1'), isNull);
      expect(TransferCode.tryParse(''), isNull);
    });

    test('version 2 → null', () {
      final text = sample().encode().replaceFirst('lxbox-transfer:1?', 'lxbox-transfer:2?');
      expect(TransferCode.tryParse(text), isNull);
    });

    test('no key, short key or broken key → null', () {
      expect(TransferCode.tryParse('lxbox-transfer:1?a=192.168.1.2:80&n=TV'), isNull);
      expect(
          TransferCode.tryParse(
              'lxbox-transfer:1?a=192.168.1.2:80&k=${encodeTransferKey(key.sublist(0, 16))}'),
          isNull);
      expect(TransferCode.tryParse('lxbox-transfer:1?a=192.168.1.2:80&k=***'), isNull);
    });

    test('bad addresses → null', () {
      final k = encodeTransferKey(key);
      for (final a in ['', '192.168.1.2', '192.168.1.2:0', '192.168.1.2:70000',
          '300.1.1.1:80', 'host.local:80', '192.168.1.2:80,']) {
        expect(TransferCode.tryParse('lxbox-transfer:1?a=$a&k=$k'), isNull,
            reason: a);
      }
    });

    test('toString masks the key (P9)', () {
      final code = sample();
      final s = code.toString();
      expect(s.contains(encodeTransferKey(key)), isFalse);
      expect(s, contains('k=***'));
      expect('$code'.contains(code.encode()), isFalse);
    });

    test('newTransferKey gives 32 fresh bytes', () {
      final a = newTransferKey();
      final b = newTransferKey();
      expect(a, hasLength(32));
      expect(a, isNot(equals(b)));
    });
  });
}
