import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/masque_keys.dart';

/// §130 — контракт DER-ключей MASQUE с ядром (sing-box-lx SPEC 021).
///
/// КРИТИЧНО: эти байты должны парситься Go `x509.ParseECPrivateKey` /
/// `ParsePKIXPublicKey`. Тут проверяем структуру ASN.1 на Dart-стороне;
/// байт-в-байт сверка с Go — в `scripts/masque_der_check.go` (см. спеку §130).
void main() {
  group('MasqueKeys DER encoding', () {
    // Детерминированный тест-вектор: известные d/x/y P-256 (не секрет — из RFC-примеров).
    // d = 1 (упрощённый вектор для проверки структуры, не для крипто-стойкости).
    final x = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    final y = Uint8List.fromList(List<int>.generate(32, (i) => 100 + i));
    final d = Uint8List.fromList(List<int>.generate(32, (i) => 200 - i));

    test('SEC1 private key парсится обратно как валидный ASN.1 SEQUENCE', () {
      final der = MasqueKeys.encodeSec1PrivateKey(d: d, x: x, y: y);
      final parsed = ASN1Parser(der).nextObject();
      expect(parsed, isA<ASN1Sequence>());
      final seq = parsed as ASN1Sequence;
      // version, privateKey, [0] params, [1] pubkey
      expect(seq.elements.length, 4);
      // version = 1
      expect((seq.elements[0] as ASN1Integer).intValue, 1);
      // privateKey OCTET STRING = d (32 байта)
      expect((seq.elements[1] as ASN1OctetString).octets, d);
      // [0] и [1] — context-specific теги
      expect(seq.elements[2].tag, 0xA0);
      expect(seq.elements[3].tag, 0xA1);
    });

    test('PKIX public key: SPKI-структура с двумя OID + BIT STRING', () {
      final der = MasqueKeys.encodePkixPublicKey(x: x, y: y);
      final seq = ASN1Parser(der).nextObject() as ASN1Sequence;
      expect(seq.elements.length, 2);
      final algId = seq.elements[0] as ASN1Sequence;
      expect((algId.elements[0] as ASN1ObjectIdentifier).identifier,
          '1.2.840.10045.2.1'); // id-ecPublicKey
      expect((algId.elements[1] as ASN1ObjectIdentifier).identifier,
          '1.2.840.10045.3.1.7'); // prime256v1
      // subjectPublicKey BIT STRING = 0x04 ‖ X ‖ Y = 65 байт
      final bits = seq.elements[1] as ASN1BitString;
      expect(bits.stringValue.length, 65);
      expect(bits.stringValue[0], 0x04); // uncompressed point marker
    });

    test('generate() даёт валидный base64 и непустые сырые координаты', () {
      final km = MasqueKeys.generate();
      expect(km.rawX.length, 32);
      expect(km.rawY.length, 32);
      expect(km.rawD.length, 32);
      // base64(DER) декодируется без ошибок
      expect(() => base64.decode(km.privateKeyDer), returnsNormally);
      expect(() => base64.decode(km.publicKeyDer), returnsNormally);
      // приватник парсится обратно в SEQUENCE
      final priv = ASN1Parser(base64.decode(km.privateKeyDer)).nextObject();
      expect(priv, isA<ASN1Sequence>());
    });

    test('normalizeServerPubKey: PEM → чистый base64(DER)', () {
      const pem = '-----BEGIN PUBLIC KEY-----\n'
          'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n'
          '-----END PUBLIC KEY-----';
      final out = MasqueKeys.normalizeServerPubKey(pem);
      expect(out, 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE');
      // голый base64 остаётся как есть
      expect(MasqueKeys.normalizeServerPubKey('  AAAA \n'), 'AAAA');
    });
  });
}
