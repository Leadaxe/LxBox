import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/platform_channels.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §557 (ядро SPEC 106) — выключатель WG/AWG-узла через MethodChannel и
/// состояние `disabled`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('§557 — CcEndpointState.disabled', () {
    test('строка ядра', () {
      expect(CcEndpointState.disabled, 'disabled');
    });

    test('disabled — не «соберётся при дайле»', () {
      expect(CcEndpointState.isNotBuilt(CcEndpointState.disabled), false);
    });
  });

  group('§557 — setEndpointEnabled', () {
    const channel = MethodChannel(PlatformChannels.methods);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('проброс tag/enabled и состояние из ответа', () async {
      late MethodCall seen;
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return 'disabled';
      });
      final st = await CcChannel.instance.setEndpointEnabled('wg-de', false);
      expect(seen.method, 'ccSetEndpointEnabled');
      expect(seen.arguments, {'tag': 'wg-de', 'enabled': false});
      expect(st, 'disabled');
    });

    test('отказ ядра — PlatformException с кодом', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'not_found',
          message: 'endpoint not found: wg-x',
        );
      });
      expect(
        () => CcChannel.instance.setEndpointEnabled('wg-x', true),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'not_found'),
        ),
      );
    });

    test('null из native — пустое состояние', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await CcChannel.instance.setEndpointEnabled('wg-de', true), '');
    });
  });
}
