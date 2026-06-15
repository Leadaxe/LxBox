import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/awg_junk.dart';

/// §126 — junk-генератор i1 для AmneziaWG обфускации.
void main() {
  // <b 0x<hex>> — hex чётной длины, lowercase.
  final cpsRe = RegExp(r'^<b 0x([0-9a-f]+)>$');

  List<int> bytesOf(String cps) {
    final m = cpsRe.firstMatch(cps)!;
    final hex = m.group(1)!;
    final out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  group('generateJunkI1 — формат', () {
    test('всегда валидный CPS-тег <b 0xHEX>, чётная длина hex', () {
      for (final t in JunkTemplate.values) {
        for (var i = 0; i < 50; i++) {
          final cps = generateJunkI1(t);
          final m = cpsRe.firstMatch(cps);
          expect(m, isNotNull, reason: 'не CPS: "$cps"');
          expect(m!.group(1)!.length.isEven, isTrue, reason: 'нечётный hex');
        }
      }
    });

    test('уникален между вызовами (Random.secure)', () {
      for (final t in JunkTemplate.values) {
        final a = generateJunkI1(t);
        final b = generateJunkI1(t);
        expect(a, isNot(b), reason: 'совпали для $t');
      }
    });
  });

  group('WG-traffic шаблон', () {
    test('fake type ∉ {0,1,2,3,4}, байты 1..3 = 0, длина ~1204..1404', () {
      for (var i = 0; i < 100; i++) {
        final bytes = bytesOf(generateJunkI1(JunkTemplate.wgTraffic));
        expect(bytes[0], greaterThanOrEqualTo(5), reason: 'type=${bytes[0]}');
        expect(bytes[1], 0);
        expect(bytes[2], 0);
        expect(bytes[3], 0);
        // 4 заголовочных + тело 1200..1400.
        expect(bytes.length, inInclusiveRange(1204, 1404));
      }
    });
  });

  group('SIP-traffic шаблон', () {
    test('валидный SIP-INVITE, без RFC-маяков, рандомизирован', () {
      for (var i = 0; i < 100; i++) {
        final text = String.fromCharCodes(
            bytesOf(generateJunkI1(JunkTemplate.sipTraffic)));
        expect(text.startsWith('INVITE sip:'), isTrue, reason: text);
        expect(text.contains('SIP/2.0'), isTrue);
        expect(text.contains('Via:'), isTrue);
        expect(text.contains('Call-ID:'), isTrue);
        expect(text.contains('CSeq:'), isTrue);
        expect(text.contains('\r\n'), isTrue, reason: 'нет CRLF');
        // Никаких захардкоженных RFC 3261 примеров.
        expect(text.contains('biloxi'), isFalse);
        expect(text.contains('atlanta'), isFalse);
        expect(text.contains('bob@'), isFalse);
        expect(text.contains('alice@'), isFalse);
        expect(text.contains('example'), isFalse);
      }
    });

    test('ASCII-only (SIP — текстовый протокол)', () {
      for (var i = 0; i < 50; i++) {
        final bytes = bytesOf(generateJunkI1(JunkTemplate.sipTraffic));
        for (final b in bytes) {
          expect(b, lessThan(128), reason: 'не-ASCII байт $b');
        }
      }
    });
  });
}
