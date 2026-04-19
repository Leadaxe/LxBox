import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/haptic_service.dart';

void main() {
  // Перехватываем платформенный канал — на host без вибро-мотора `HapticFeedback`
  // швыряет MissingPluginException. В сервисном коде на устройстве Flutter сам
  // глушит это, но в тесте — нет.
  TestWidgetsFlutterBinding.ensureInitialized();
  var platformCalls = 0;
  setUp(() {
    platformCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') platformCalls++;
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('HapticService', () {
    test('enabled=false → no platform calls', () async {
      final h = HapticService(enabled: false);
      h.onVpnConnected();
      h.onConnectTap();
      h.onHeartbeatFail();
      // Дать tick'у пройти, async вызовы успевают добежать
      await Future<void>.delayed(Duration.zero);
      expect(platformCalls, 0);
    });

    test('enabled=true → fires platform call', () async {
      final h = HapticService(enabled: true);
      h.onVpnConnected();
      await Future<void>.delayed(Duration.zero);
      expect(platformCalls, 1);
    });

    test('throttle blocks rapid duplicate fires', () async {
      final h = HapticService(
        enabled: true,
        throttle: const Duration(milliseconds: 100),
      );
      h.onVpnConnected();    // fires
      h.onVpnConnected();    // throttled
      h.onVpnConnected();    // throttled
      h.onVpnDisconnected(); // throttled (any event uses common throttle)
      await Future<void>.delayed(Duration.zero);
      expect(platformCalls, 1);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      h.onVpnConnected(); // throttle прошёл
      await Future<void>.delayed(Duration.zero);
      expect(platformCalls, 2);
    });

    test('disabled service ignores everything', () async {
      final h = HapticService(enabled: false, throttle: const Duration(seconds: 10));
      for (var i = 0; i < 100; i++) {
        h.onVpnConnected();
        h.onConnectTap();
        h.onFetchError();
      }
      await Future<void>.delayed(Duration.zero);
      expect(platformCalls, 0);
    });

    test('toggling enabled mid-flight applies immediately', () async {
      final h = HapticService(enabled: true, throttle: Duration.zero);
      h.onVpnConnected();
      await Future<void>.delayed(Duration.zero);
      expect(platformCalls, 1);
      h.enabled = false;
      h.onVpnConnected(); // skipped
      await Future<void>.delayed(Duration.zero);
      expect(platformCalls, 1);
      h.enabled = true;
      h.onVpnConnected(); // resumed
      await Future<void>.delayed(Duration.zero);
      expect(platformCalls, 2);
    });

    test('singleton instance accessible and toggleable', () {
      final initial = HapticService.I.enabled;
      HapticService.I.enabled = false;
      expect(HapticService.I.enabled, isFalse);
      HapticService.I.enabled = true;
      expect(HapticService.I.enabled, isTrue);
      // restore
      HapticService.I.enabled = initial;
    });
  });
}
