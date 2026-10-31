import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/platform_channels.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §208 — `CcPoolSlot.fromMap` (снапшот пула round_robin, GetPool RPC).
/// §209 — `CcChannel.getPool` различает null (клиент недоступен) от [] (пусто).
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
}
