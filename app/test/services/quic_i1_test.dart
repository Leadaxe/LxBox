import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/aes_min.dart';
import 'package:lxbox/services/warp/quic_i1.dart';

/// §136 — QUIC Initial генератор: крипта (AES) против эталонов + структура i1.
void main() {
  List<int> hex(String s) {
    final out = <int>[];
    for (var i = 0; i < s.length; i += 2) {
      out.add(int.parse(s.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  String toHex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  group('AesMin — корректность против известных векторов', () {
    test('AES-128 ECB block (FIPS-197 example)', () {
      // FIPS-197 Appendix B: key=000102…0f, pt=00112233…ff → ct=69c4e0d8…0a.
      final key = hex('000102030405060708090a0b0c0d0e0f');
      final pt = hex('00112233445566778899aabbccddeeff');
      final ct = AesMin(key).encryptBlock(pt);
      expect(toHex(ct), '69c4e0d86a7b0430d8cdb78070b4c55a');
    });

    test('AES-128-GCM (NIST GCM TC3, aad=пусто)', () {
      // NIST GCM TC3: key=feffe9928665731c…, iv=cafebabefacedbaddecaf888,
      // pt=d9313225f88406e5…(60B), aad='' → ct+tag (сверено с cryptography).
      final key = hex('feffe9928665731c6d6a8f9467308308');
      final iv = hex('cafebabefacedbaddecaf888');
      final pt = hex('d9313225f88406e5a55909c5aff5269a'
          '86a7a9531534f7da2e4c303d8a318a72'
          '1c3c0c95956809532fcf0e2449a6b525'
          'b16aedf5aa0de657ba637b39');
      final out = AesMin(key).gcmEncrypt(iv, pt, const []);
      final ct = out.sublist(0, pt.length);
      final tag = out.sublist(pt.length);
      expect(
          toHex(ct),
          '42831ec2217774244b7221b784d0d49c'
          'e3aa212f2c02a4e035c17e2329aca12e'
          '21d514b25466931c7d8f6a5aac84aa05'
          '1ba30b396a0aac973d58e091');
      expect(toHex(tag), 'cc15abcc191161501aabab46b8fbac85');
    });

    test('AES-128-GCM с AAD (NIST GCM TC4)', () {
      // TC4: тот же ключ/iv, pt=60B, aad=feedfacedeadbeef…(20B).
      final key = hex('feffe9928665731c6d6a8f9467308308');
      final iv = hex('cafebabefacedbaddecaf888');
      final pt = hex('d9313225f88406e5a55909c5aff5269a'
          '86a7a9531534f7da2e4c303d8a318a72'
          '1c3c0c95956809532fcf0e2449a6b525'
          'b16aedf5aa0de657ba637b39');
      final aad = hex('feedfacedeadbeeffeedfacedeadbeefabaddad2');
      final out = AesMin(key).gcmEncrypt(iv, pt, aad);
      final tag = out.sublist(pt.length);
      expect(toHex(tag), '5bc94fbc3221a5db94fae95ae7121a47');
    });
  });

  group('QUIC key derivation (RFC 9001 A.1 via HMAC)', () {
    // Подтверждает что quic.js-style deriveSecret даёт RFC-эталонные ключи.
    List<int> expandLabel(List<int> secret, String label, int length) {
      final full = 'tls13 $label'.codeUnits;
      final data = <int>[
        (length >> 8) & 0xff, length & 0xff,
        full.length, ...full,
        0, // str8('')
        0x01,
      ];
      return crypto.Hmac(crypto.sha256, secret)
          .convert(data)
          .bytes
          .sublist(0, length);
    }

    test('key/iv/hp совпадают с RFC 9001 A.1', () {
      final salt = hex('38762cf7f55934b34d179ae6a4c80cadccbb7f0a');
      final dcid = hex('8394c8f03e515708');
      final initial = crypto.Hmac(crypto.sha256, salt).convert(dcid).bytes;
      final client = expandLabel(initial, 'client in', 32);
      expect(toHex(expandLabel(client, 'quic key', 16)),
          '1f369613dd76d5467730efcbe3b1a22d');
      expect(toHex(expandLabel(client, 'quic iv', 12)),
          'fa044b2f42a3fd3b46fb255c');
      expect(toHex(expandLabel(client, 'quic hp', 16)),
          '9f50449e04a0e810283a1e9933adedd2');
    });
  });

  group('QuicI1.generate — как рабочий эталон (🟡 QUIC-google)', () {
    List<int> hexBytes(String cps) {
      final h = RegExp(r'^<b 0x([0-9a-f]+)>$').firstMatch(cps)!.group(1)!;
      final out = <int>[];
      for (var i = 0; i < h.length; i += 2) {
        out.add(int.parse(h.substring(i, i + 2), radix: 16));
      }
      return out;
    }

    test('сплошной <b>, БЕЗ <r> (узел с <r> у Ильи НЕ работал)', () {
      final cps = QuicI1.generate('www.google.com');
      expect(cps.contains('<r '), isFalse, reason: '<r> ломает i1');
      expect(RegExp(r'^<b 0x[0-9a-f]+>$').hasMatch(cps), isTrue,
          reason: 'не один сплошной <b>');
    });

    test('размер 1250б, length-поле 1232 (байт-в-байт с рабочим)', () {
      final b = hexBytes(QuicI1.generate('www.google.com'));
      expect(b.length, 1250);
      // length varint @16 (2 байта)
      expect(((b[16] & 0x3f) << 8) | b[17], 1232);
    });

    test('QUIC long-header Initial, version 1, DCID=8', () {
      final b = hexBytes(QuicI1.generate('rzd.ru'));
      expect(b[0] & 0xc0, 0xc0); // long header
      expect(b[0] & 0x30, 0x00); // Initial type
      expect(b.sublist(1, 5), [0, 0, 0, 1]); // version 1
      expect(b[5], 8); // DCID len = 8 (как в рабочем)
    });

    test('уникальность между вызовами (Random.secure)', () {
      expect(QuicI1.generate('a.io'), isNot(QuicI1.generate('a.io')));
    });
  });
}
