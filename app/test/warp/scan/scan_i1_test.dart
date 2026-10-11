// §841 — тесты I1-генераторов (порт warpscout i1gen_test.go).
// Проверяем: цепочка валидная, начинается с `<`, содержит `<b 0x` и `<r/rc/rd`,
// лишних символов нет, детерминированность формы (для одного протокола).
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/warp/scan/scan_i1.dart';

void main() {
  group('genI1', () {
    test('quic: валидная цепочка с литеральными байтами и random', () {
      for (var i = 0; i < 5; i++) {
        final chain = genI1('quic', 'www.apple.com');
        expect(validI1Chain(chain), isTrue, reason: 'цепочка непустая <…>');
        expect(chain, startsWith('<b 0x'), reason: 'начинается с литеральных байт');
        expect(chain.contains('<r '), isTrue,
            reason: 'содержит случайную часть (<r N>)');
        // В QUIC-цепочке нет «голых» не-командных символов.
        expect(chain.contains('OPTIONS'), isFalse);
        expect(chain.contains('sip:'), isFalse);
      }
    });

    test('dns: валидная цепочка с DNS-запросом и padding', () {
      final chain = genI1('dns', 'www.google.com');
      expect(validI1Chain(chain), isTrue);
      expect(chain, startsWith('<r 2>'), reason: 'transaction id = рандом');
      expect(chain.contains('<b 0x'), isTrue);
      // padding option <r N> в конце
      expect(RegExp(r'<r \d+>$').hasMatch(chain), isTrue,
          reason: 'хвост — рандомный padding (RFC 7830)');
    });

    test('stun: валидная цепочка STUN Binding Request', () {
      final chain = genI1('stun');
      expect(validI1Chain(chain), isTrue);
      expect(chain.contains('<b 0x0001'), isTrue, reason: 'Binding Request');
      expect(chain.contains('2112a442'), isTrue,
          reason: 'magic cookie 0x2112A442');
      expect(chain.contains('<rc '), isTrue, reason: 'SOFTWARE attr printable');
    });

    test('sip: валидная цепочка SIP OPTIONS', () {
      final chain = genI1('sip', 'www.cloudflare.com');
      expect(validI1Chain(chain), isTrue);
      // <b 0x…> = "OPTIONS sip:" (hex: 4f 50 54 49 4f 4e 53 20 73 69 70 3a)
      expect(chain, startsWith('<b 0x4f5054494f4e53207369703a'),
          reason: 'начинается с "OPTIONS sip:"');
      // hex для "Via: SIP/2.0/UDP 192.168." → 56 69 61 3a 20 53 49 50 2f…
      expect(chain.contains('<b 0x5669613a205349502f322e302f554450203139322e3136382e'),
          isTrue, reason: 'hex Via заголовок');
      // hex для "Max-Forwards: 70" → 4d 61 78 2d 46 6f 72 77 61 72 64 73 3a 20 37 30
      expect(chain.contains('4d61782d466f7277617264733a203730'),
          isTrue, reason: 'hex Max-Forwards');
    });

    test('random: выбирает один из профилей', () {
      for (var i = 0; i < 20; i++) {
        final chain = genI1('random');
        expect(validI1Chain(chain), isTrue);
      }
    });

    test('пустой host → подставляется из kI1Hosts', () {
      final chain = genI1('quic');
      expect(validI1Chain(chain), isTrue);
    });
  });

  group('dns label', () {
    test('корректное кодирование имени', () {
      // через DNS-генератор: хост с несколькими метками
      // wire-формат: 03 'cdn' 08 'jsdelivr' 03 'net' 00
      final chain = genI1('dns', 'cdn.jsdelivr.net');
      expect(chain.contains('<b 0x0363646e086a7364656c697672036e657400'), isTrue,
          reason: '"cdn.jsdelivr.net" в DNS wire-формате (8-ми байтовая метка)');
    });
  });
}