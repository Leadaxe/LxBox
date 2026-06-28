import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §208 — `CcPoolSlot.fromMap` (снапшот пула round_robin, GetPool RPC).
void main() {
  group('§208 — CcPoolSlot.fromMap', () {
    test('живой слот: slot/tag/delay', () {
      final s = CcPoolSlot.fromMap({'slot': 1, 'tag': 'node-de', 'delay': 42});
      expect(s.slot, 1);
      expect(s.tag, 'node-de');
      expect(s.delay, 42);
      expect(s.alive, true);
    });

    test('delay 0 → мёртвая/не измерена (alive=false)', () {
      final s = CcPoolSlot.fromMap({'slot': 2, 'tag': 'node-fi', 'delay': 0});
      expect(s.delay, 0);
      expect(s.alive, false);
    });

    test('дефолты при отсутствующих ключах', () {
      final s = CcPoolSlot.fromMap(const {});
      expect(s.slot, 0);
      expect(s.tag, '');
      expect(s.delay, 0);
      expect(s.alive, false);
    });

    test('num (double из platform channel) приводится к int', () {
      final s = CcPoolSlot.fromMap({'slot': 0.0, 'tag': 'x', 'delay': 12.0});
      expect(s.slot, 0);
      expect(s.delay, 12);
    });
  });
}
