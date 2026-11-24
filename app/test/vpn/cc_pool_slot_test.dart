import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/vpn/platform_channels.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §208 — `CcPoolSlot.fromMap` (снапшот пула round_robin, GetPool RPC).
/// §209 — `CcChannel.getPool` различает null (клиент недоступен) от [] (пусто).
/// §759 — карантин, счётчики слота и состояние группы (`getPoolState`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
  group('§759 — состояние самовосстановления пула (ядро SPEC 138)', () {
    const channel = MethodChannel(PlatformChannels.methods);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('CcPoolSlot.fromMap: карантин и счётчики; без полей — нули', () {
      final q = CcPoolSlot.fromMap(const {
        'slot': 2,
        'tag': 'node-de',
        'delay': 87,
        'quarantined': true,
        'connections': 40,
        'confirmedFailures': 6,
      });
      expect(q.quarantined, isTrue);
      expect(q.connections, 40);
      expect(q.confirmedFailures, 6);
      // У узла в карантине задержка не нулевая: карантин — отдельный признак.
      expect(q.alive, isTrue);

      final old =
          CcPoolSlot.fromMap(const {'slot': 0, 'tag': 'node-fi', 'delay': 12});
      expect(old.quarantined, isFalse);
      expect(old.connections, 0);
      expect(old.confirmedFailures, 0);
    });

    test('карта от нативной части → слоты и состояние группы', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'ccGetPool');
        return <dynamic, dynamic>{
          'shiftedKeys': 3,
          'markedKeys': 1,
          'frozen': true,
          'frozenSeconds': 12,
          'slots': <dynamic>[
            {'slot': 0, 'tag': 'node-de', 'delay': 12, 'connections': 5},
            {'slot': 1, 'tag': 'node-fi', 'delay': 90, 'quarantined': true},
          ],
        };
      });
      final s = await CcChannel.instance.getPoolState('vpn-1-auto');
      expect(s, isNotNull);
      expect(s!.shiftedKeys, 3);
      expect(s.markedKeys, 1);
      expect(s.frozen, isTrue);
      expect(s.frozenSeconds, 12);
      expect(s.hasSelfHealState, isTrue);
      expect(s.slots.length, 2);
      expect(s.slots[0].connections, 5);
      expect(s.slots[1].quarantined, isTrue);
      // Старый вызов поверх того же ответа отдаёт те же слоты.
      final slots = await CcChannel.instance.getPool('vpn-1-auto');
      expect(slots!.map((e) => e.tag), ['node-de', 'node-fi']);
    });

    test('список слотов (ядро без GetPoolState) → состояние нулевое',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async => <dynamic>[
            {'slot': 0, 'tag': 'node-de', 'delay': 12},
          ]);
      final s = await CcChannel.instance.getPoolState('vpn-1-auto');
      expect(s!.slots.single.tag, 'node-de');
      expect(s.shiftedKeys, 0);
      expect(s.markedKeys, 0);
      expect(s.frozen, isFalse);
      expect(s.hasSelfHealState, isFalse);
    });

    test('native вернул null → getPoolState возвращает null', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await CcChannel.instance.getPoolState('vpn-1-auto'), isNull);
    });
  });
}
