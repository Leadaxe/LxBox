import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/platform_channels.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §208 — `CcPoolSlot.fromMap` (снапшот пула round_robin, GetPool RPC).
/// §209 — `CcChannel.getPool` различает null (клиент недоступен) от [] (пусто).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('§209 — CcChannel.getPool null vs [] (клиент недоступен vs пусто)', () {
    const channel = MethodChannel(PlatformChannels.methods);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('native вернул null → getPool возвращает null (недоступно)', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'ccGetPool');
        return null; // клиент недоступен (§209)
      });
      final r = await CcChannel.instance.getPool('vpn-1-auto');
      expect(r, isNull);
    });

    test('native вернул [] → getPool возвращает [] (пул пуст)', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => <dynamic>[]);
      final r = await CcChannel.instance.getPool('vpn-1-auto');
      expect(r, isNotNull);
      expect(r, isEmpty);
    });

    test('native вернул слоты → распарсены в CcPoolSlot', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => <dynamic>[
            {'slot': 0, 'tag': 'node-de', 'delay': 12},
            {'slot': 1, 'tag': 'node-fi', 'delay': 0},
          ]);
      final r = await CcChannel.instance.getPool('vpn-1-auto');
      expect(r, isNotNull);
      expect(r!.length, 2);
      expect(r[0].tag, 'node-de');
      expect(r[0].alive, true);
      expect(r[1].alive, false); // delay 0
    });
  });
}
