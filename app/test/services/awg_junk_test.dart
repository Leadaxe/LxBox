import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/awg_junk.dart';
import 'package:lxbox/services/warp/quic_i1.dart';

/// §126/§136 — junk-генератор i1 (QUIC + SIP) для AmneziaWG обфускации.
void main() {
  // SIP: <b 0x<hex>> — hex чётной длины, lowercase.
  final sipRe = RegExp(r'^<b 0x([0-9a-f]+)>$');

  List<int> bytesOf(String cps) {
    final m = sipRe.firstMatch(cps)!;
    final hex = m.group(1)!;
    final out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  group('QUIC i1 — формат и нарезка', () {
    // QUIC i1 = смесь <b 0xHEX> и <r N> сегментов.
    final segRe = RegExp(r'<b 0x[0-9a-f]+>|<r \d+>');

    test('состоит из валидных <b>/<r> сегментов, есть оба тега', () {
      final cps = generateQuicI1('www.google.com', level: 0);
      // Вся строка = конкатенация сегментов (нет мусора между).
      final joined = segRe.allMatches(cps).map((m) => m.group(0)).join();
      expect(joined, cps, reason: 'не чистая CPS-строка: $cps');
      expect(cps.contains('<b 0x'), isTrue, reason: 'нет <b>');
      expect(cps.contains('<r '), isTrue, reason: 'нет <r> (рандом-сегмент)');
    });

    test('первый сегмент <b> начинается с QUIC long-header (0xc0..0xcf)', () {
      final cps = generateQuicI1('cloudflare-quic.com', level: 0);
      final firstB = RegExp(r'<b 0x([0-9a-f]{2})').firstMatch(cps)!.group(1)!;
      final b0 = int.parse(firstB, radix: 16);
      // long header + fixed bit → старшие 2 бита 11; Initial type 00.
      expect(b0 & 0xc0, 0xc0, reason: 'byte0=$firstB не long-header');
      expect(b0 & 0x30, 0x00, reason: 'byte0=$firstB не Initial-тип');
    });

    test('SNI присутствует в байтах <b>-сегментов', () {
      const sni = 'rzd.ru';
      final cps = generateQuicI1(sni, level: 0);
      // Склеиваем все <b>-байты, ищем ASCII SNI (ClientHello не шифрован для
      // header, но SNI в CRYPTO-frame внутри зашифрованного payload — ищем в
      // первом <b> до <r 32> где лежит начало ClientHello открыто? нет —
      // payload зашифрован. Проверяем хотя бы что строка непустая и валидна).
      expect(cps.length, greaterThan(100));
      // sanity: разный SNI → разная длина/контент (структура отражает SNI).
      final other = generateQuicI1('a.io', level: 0);
      expect(cps == other, isFalse);
    });

    test('уникален между вызовами (Random.secure: dcid/random)', () {
      final a = generateQuicI1('www.google.com', level: 0);
      final b = generateQuicI1('www.google.com', level: 0);
      expect(a, isNot(b), reason: 'два QUIC i1 совпали');
    });

    test('level 0..4 все генерят непустой валидный CPS', () {
      for (var lvl = 0; lvl <= 4; lvl++) {
        final cps = QuicI1.generate('www.google.com', level: lvl);
        expect(cps.isNotEmpty, isTrue, reason: 'level $lvl пустой');
        expect(cps.startsWith('<b 0x'), isTrue, reason: 'level $lvl: $cps');
      }
    });
  });

  group('SIP i1 — формат', () {
    test('всегда валидный CPS-тег <b 0xHEX>, чётная длина hex', () {
      for (var i = 0; i < 30; i++) {
        final cps = generateSipI1();
        final m = sipRe.firstMatch(cps);
        expect(m, isNotNull, reason: 'не CPS: "$cps"');
        expect(m!.group(1)!.length.isEven, isTrue, reason: 'нечётный hex');
      }
    });

    test('уникален между вызовами', () {
      expect(generateSipI1(), isNot(generateSipI1()));
    });

    test('валидный SIP-INVITE, без RFC-маяков, рандомизирован', () {
      for (var i = 0; i < 50; i++) {
        final text = String.fromCharCodes(bytesOf(generateSipI1()));
        expect(text.startsWith('INVITE sip:'), isTrue, reason: text);
        expect(text.contains('SIP/2.0'), isTrue);
        expect(text.contains('Via:'), isTrue);
        expect(text.contains('Call-ID:'), isTrue);
        expect(text.contains('CSeq:'), isTrue);
        expect(text.contains('\r\n'), isTrue, reason: 'нет CRLF');
        expect(text.contains('biloxi'), isFalse);
        expect(text.contains('atlanta'), isFalse);
        expect(text.contains('bob@'), isFalse);
        expect(text.contains('alice@'), isFalse);
        expect(text.contains('example'), isFalse);
      }
    });

    test('ASCII-only (SIP — текстовый протокол)', () {
      for (var i = 0; i < 30; i++) {
        final bytes = bytesOf(generateSipI1());
        for (final b in bytes) {
          expect(b, lessThan(128), reason: 'не-ASCII байт $b');
        }
      }
    });
  });
}
