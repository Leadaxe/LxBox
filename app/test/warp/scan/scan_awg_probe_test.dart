// §841 — тесты обфусцированного залпа AWG: состав и порядок.
//
// Корень «снова нет живых»: фаза 1 слала ГОЛЫЙ WG-init → DPI МегаФона режет
// по сигнатуре. Живой ответ даёт только залп AmneziaWG:
//   [I1] + [junk × jc] + [WG-init]
// Проверяем ровно то, что решает живость: I1 первым, junk до init, init
// последним, длины junk в jmin..jmax, обе ветки (с I1 и без).
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/scan_awg_probe.dart';
import 'package:lxbox/services/warp/scan/scan_i1.dart';

void main() {
  group('buildAwgBurst', () {
    test('порядок: I1 первым, junk, WG-init последним', () {
      final init = Uint8List.fromList(List.filled(148, 7));
      final burst = buildAwgBurst(init: init, rng: Random(42));
      // 1 (I1) + 6 (junk по умолчанию jc=6) + 1 (init)
      expect(burst.length, 8);
      // I1 — рендер дефолтной цепочки (44 Б).
      expect(burst.first.length, 44);
      // Последний пакет — это ровно наш init (последний ход handshake).
      expect(burst.last, equals(init));
      // Ни один junk/init не притворяется I1.
      for (var i = 1; i < burst.length - 1; i++) {
        expect(burst[i].length,
            inInclusiveRange(10, 50),
            reason: 'junk[$i] длина вне jmin..jmax');
      }
    });

    test('obfuscate=false — без I1 (только junk+init, как -i1 none)', () {
      final init = Uint8List.fromList(List.filled(148, 1));
      final burst = buildAwgBurst(init: init, obfuscate: false, rng: Random(1));
      expect(burst.length, 7);
      expect(burst.last, equals(init));
      for (var i = 0; i < burst.length - 1; i++) {
        expect(burst[i].length, inInclusiveRange(10, 50));
      }
    });

    test('jc=0 → только I1 + init', () {
      final init = Uint8List.fromList(List.filled(148, 2));
      final burst = buildAwgBurst(init: init, jc: 0, rng: Random(2));
      expect(burst.length, 2);
      expect(burst.first.length, 44);
      expect(burst.last, equals(init));
    });

    test('jc=0 и obfuscate=false → один init (деградация к голому WG)', () {
      final init = Uint8List.fromList(List.filled(148, 3));
      final burst =
          buildAwgBurst(init: init, jc: 0, obfuscate: false, rng: Random(3));
      expect(burst.length, 1);
      expect(burst.single, equals(init));
    });

    test('jmin/jmax соблюдаются при узком диапазоне', () {
      final init = Uint8List.fromList(List.filled(148, 4));
      final burst = buildAwgBurst(
        init: init,
        jc: 12,
        jmin: 8,
        jmax: 9,
        rng: Random(4),
      );
      for (var i = 1; i < burst.length - 1; i++) {
        expect(burst[i].length, anyOf(8, 9));
      }
    });

    test('junk непостоянен (не один и тот же буфер)', () {
      final init = Uint8List.fromList(List.filled(148, 5));
      final burst = buildAwgBurst(init: init, rng: Random(5));
      final junks = burst.sublist(1, burst.length - 1);
      final distinct = junks.map((j) => j.join(',')).toSet();
      expect(distinct.length, greaterThan(1),
          reason: 'junk должен быть случайным, иначе DPI видит шаблон');
    });

    test('дефолтная I1-цепочка рендерится в 44 байта (как захват эталона)', () {
      final b = renderI1Chain(kI1DefaultChain, rng: Random(9));
      expect(b.length, 44);
      // Хвост — фиксированный fake-DNS-ответ icloud.com → MX77.
      expect(b.sublist(2).map((x) => x.toRadixString(16).padLeft(2, '0')).join(),
          '858000010001000000000669636c6f756403636f6d0000010001'
          'c00c000100010000105a00044d583737');
    });
  });
}
