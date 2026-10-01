import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/platform_channels.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// P2 (012-LIVE_STATE / FEATURE.md) — «Frequency is cut at the source»: the
/// status tick is NORMAL (0.5s) at home, FAST (0.1s) while Statistics is
/// open, 0 in the background. The native frequency switch itself is not
/// observable from a Dart unit test (native energy model, task 164); the
/// Dart-side contract that gates it is `CcChannel.setStatusFast`, called
/// exactly by `StatsScreen.initState`/`dispose` (task 164 §4 "Dart —
/// stats_screen.dart"). `no witness` in FEATURE.md.
///
/// Mutation this test must catch: `setStatusFast` stops sending `fast` as an
/// argument, or sends it under the wrong key/method name — Stats would then
/// silently fail to raise/lower the native tick rate.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P2 — setStatusFast проброс аргумента', () {
    const channel = MethodChannel(PlatformChannels.methods);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('true — Stats открыт (FAST 0.1с)', () async {
      late MethodCall seen;
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return null;
      });
      await CcChannel.instance.setStatusFast(true);
      expect(seen.method, 'ccSetStatusFast');
      expect(seen.arguments, {'fast': true});
    });

    test('false — Stats закрыт (возврат на NORMAL 0.5с)', () async {
      late MethodCall seen;
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return null;
      });
      await CcChannel.instance.setStatusFast(false);
      expect(seen.method, 'ccSetStatusFast');
      expect(seen.arguments, {'fast': false});
    });

    test('нативная ошибка/недоступность — не бросает (best-effort)', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'not_ready');
      });
      // Не должно бросить наружу — Stats не должен падать, если native ещё
      // не готов (тот же контракт, что у остальных CC-вызовов).
      await CcChannel.instance.setStatusFast(true);
    });
  });
}
