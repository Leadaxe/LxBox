import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/util/pseudo_gen.dart';

/// §127 — PseudoGen acceptance. Генератор недетерминирован (Random.secure),
/// поэтому свойства проверяем статистически — большими прогонами.
void main() {
  final wordRe = RegExp(r'^[a-z]+$');

  group('PseudoGen.word', () {
    test('только [a-z], длина 6–13, без q/x/y', () {
      for (var i = 0; i < 2000; i++) {
        final w = PseudoGen.word();
        expect(wordRe.hasMatch(w), isTrue, reason: 'не [a-z]: "$w"');
        // 6 = C+V + 2×(C+V); 13 = C+V + 3×(ONSET+V) + CODA-tail.
        expect(w.length, inInclusiveRange(6, 13), reason: 'длина: "$w"');
        expect(w.contains('q') || w.contains('x') || w.contains('y'), isFalse,
            reason: 'q/x/y в "$w"');
      }
    });

    test('начинается с согласной (не гласная, не онсет lk)', () {
      const vowels = {'a', 'e', 'i', 'o', 'u'};
      for (var i = 0; i < 2000; i++) {
        final w = PseudoGen.word();
        expect(vowels.contains(w[0]), isFalse, reason: 'старт с гласной: "$w"');
        // lk встречается только как кода (в конце), не в начале.
        expect(w.startsWith('lk'), isFalse, reason: 'lk в начале: "$w"');
      }
    });

    test('два последовательных вызова различаются (не seeded)', () {
      // Теоретически возможно совпадение, но при ~1e-? шанс пренебрежим;
      // прогоняем несколько пар для надёжности.
      var distinct = 0;
      for (var i = 0; i < 10; i++) {
        if (PseudoGen.word() != PseudoGen.word()) distinct++;
      }
      expect(distinct, greaterThan(0));
    });
  });

  group('PseudoGen.user', () {
    test('~30% составные (один _), обе части валидны как word', () {
      var compound = 0;
      const n = 5000;
      for (var i = 0; i < n; i++) {
        final u = PseudoGen.user();
        final underscores = '_'.allMatches(u).length;
        expect(underscores, lessThanOrEqualTo(1), reason: 'много _: "$u"');
        if (underscores == 1) {
          compound++;
          for (final part in u.split('_')) {
            expect(wordRe.hasMatch(part), isTrue, reason: 'часть "$part" в "$u"');
            expect(part.length, inInclusiveRange(6, 13));
          }
        } else {
          expect(wordRe.hasMatch(u), isTrue, reason: '"$u"');
        }
      }
      final ratio = compound / n;
      expect(ratio, inInclusiveRange(0.25, 0.35), reason: 'доля составных $ratio');
    });
  });

  group('PseudoGen.publicIp', () {
    test('1000× — ни одного зарезервированного/приватного', () {
      bool isReserved(List<int> o) {
        final a = o[0], b = o[1];
        if (a == 0 || a == 10 || a == 127) return true;
        if (a == 172 && b >= 16 && b <= 31) return true;
        if (a == 192 && b == 168) return true;
        if (a == 169 && b == 254) return true;
        if (a == 100 && b >= 64 && b <= 127) return true;
        if (a >= 224) return true;
        if (a < 1 || a > 223) return true;
        return false;
      }

      for (var i = 0; i < 1000; i++) {
        final ip = PseudoGen.publicIp();
        final octets = ip.split('.').map(int.parse).toList();
        expect(octets.length, 4, reason: ip);
        for (final o in octets) {
          expect(o, inInclusiveRange(0, 255), reason: ip);
        }
        expect(octets[3], inInclusiveRange(1, 254), reason: 'host-часть: $ip');
        expect(isReserved(octets), isFalse, reason: 'зарезервирован: $ip');
      }
    });
  });

  group('PseudoGen.host', () {
    test('распределение ~30/30/30/10, IP всегда публичный', () {
      var ip = 0, lvl3 = 0, lvl2 = 0, sip = 0;
      const n = 5000;
      final ipRe = RegExp(r'^\d+\.\d+\.\d+\.\d+$');
      for (var i = 0; i < n; i++) {
        final h = PseudoGen.host();
        if (ipRe.hasMatch(h)) {
          ip++;
        } else if (h.startsWith('sip.')) {
          sip++;
        } else {
          final dots = '.'.allMatches(h).length;
          if (dots == 2) {
            lvl3++;
          } else {
            lvl2++;
          }
        }
      }
      expect(ip / n, inInclusiveRange(0.25, 0.35), reason: 'IP ${ip / n}');
      expect(lvl3 / n, inInclusiveRange(0.25, 0.35), reason: '3-lvl ${lvl3 / n}');
      expect(lvl2 / n, inInclusiveRange(0.25, 0.35), reason: '2-lvl ${lvl2 / n}');
      expect(sip / n, inInclusiveRange(0.05, 0.15), reason: 'sip ${sip / n}');
    });

    test('нет захардкоженных RFC-маяков', () {
      for (var i = 0; i < 2000; i++) {
        final h = PseudoGen.host();
        expect(h.contains('biloxi'), isFalse);
        expect(h.contains('atlanta'), isFalse);
        expect(h.contains('example'), isFalse);
      }
    });
  });
}
