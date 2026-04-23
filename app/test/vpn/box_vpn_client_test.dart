import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/vpn/box_vpn_client.dart';

/// Narrow contract tests для MethodChannel'а VpnPlugin.
/// Рендерить AppSettingsScreen целиком избыточно — он тянет SettingsStorage
/// (path_provider), HapticService и 10+ других channels. Здесь проверяется
/// только то, что Dart wrapper правильно пакует аргументы в native call —
/// этого достаточно чтобы регрессия в сигнатуре (например `'mode'` → `'value'`)
/// упала сразу, без запуска Android.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.leadaxe.lxbox/methods');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getBackgroundMode':
          return 'never';
        case 'setBackgroundMode':
          return null;
        case 'areNotificationsEnabled':
          return true;
        case 'isIgnoringBatteryOptimizations':
          return false;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('BoxVpnClient.setBackgroundMode', () {
    test('passes mode argument verbatim to native', () async {
      await BoxVpnClient().setBackgroundMode('lazy');
      expect(calls.single.method, equals('setBackgroundMode'));
      expect(calls.single.arguments, equals({'mode': 'lazy'}));
    });

    test('accepts all three documented values', () async {
      final client = BoxVpnClient();
      for (final mode in ['never', 'lazy', 'always']) {
        await client.setBackgroundMode(mode);
      }
      expect(calls.map((c) => c.arguments['mode']).toList(),
          equals(['never', 'lazy', 'always']));
    });
  });

  group('BoxVpnClient.getBackgroundMode', () {
    test('returns native value', () async {
      final m = await BoxVpnClient().getBackgroundMode();
      expect(m, equals('never'));
      expect(calls.single.method, equals('getBackgroundMode'));
    });
  });

  group('BoxVpnClient.areNotificationsEnabled / isIgnoringBatteryOptimizations', () {
    test('both return native booleans', () async {
      final notif = await BoxVpnClient().areNotificationsEnabled();
      final batt = await BoxVpnClient().isIgnoringBatteryOptimizations();
      expect(notif, isTrue);
      expect(batt, isFalse);
    });
  });
}
