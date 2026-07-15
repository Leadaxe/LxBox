import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/background_mode.dart';
import 'package:lxbox/models/tunnel_status.dart';
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
    test('passes mode wireValue to native', () async {
      await BoxVpnClient().setBackgroundMode(BackgroundMode.lazy);
      expect(calls.single.method, equals('setBackgroundMode'));
      expect(calls.single.arguments, equals({'mode': 'lazy'}));
    });

    test('serializes all three enum values via wireValue', () async {
      final client = BoxVpnClient();
      for (final mode in BackgroundMode.values) {
        await client.setBackgroundMode(mode);
      }
      expect(calls.map((c) => c.arguments['mode']).toList(),
          equals(['never', 'lazy', 'always']));
    });
  });

  group('BoxVpnClient.getBackgroundMode', () {
    test('parses native string into enum', () async {
      final m = await BoxVpnClient().getBackgroundMode();
      expect(m, equals(BackgroundMode.never));
      expect(calls.single.method, equals('getBackgroundMode'));
    });
  });

  // §271 — memory limit: контракт wire-значений + нормализация ответов native.
  group('BoxVpnClient memory limit (§271)', () {
    test('setMemoryLimit passes value to native', () async {
      await BoxVpnClient().setMemoryLimit('512');
      expect(calls.single.method, equals('setMemoryLimit'));
      expect(calls.single.arguments, equals({'value': '512'}));
    });

    test('setMemoryLimit normalizes garbage to auto before sending', () async {
      await BoxVpnClient().setMemoryLimit('banana');
      expect(calls.single.arguments, equals({'value': 'auto'}));
    });

    test('getMemoryLimit normalizes unknown native value to auto', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return 'legacy-junk';
      });
      expect(await BoxVpnClient().getMemoryLimit(), equals('auto'));
    });

    test('getMemoryLimit returns valid native value as is', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return 'off';
      });
      expect(await BoxVpnClient().getMemoryLimit(), equals('off'));
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

  // §109 — контракт getAppInfo: null ТОЛЬКО при подтверждённом not-found;
  // timeout/ошибка канала обязаны бросать, не маскироваться под null
  // (регрессия: ложный «uninstalled, auto-skipped» на Tunnel apps).
  group('BoxVpnClient.getAppInfo (§109)', () {
    test('{notFound: true} → null (подтверждённый not-found)', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return {'notFound': true};
      });
      final info = await BoxVpnClient().getAppInfo('com.gone.app');
      expect(info, isNull);
    });

    test('metadata map → AppInfo (иконки в ответе больше нет)', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.arguments, equals({'packageName': 'ru.fourpda.client'}));
        return {
          'packageName': 'ru.fourpda.client',
          'appName': '4PDA',
          'isSystemApp': false,
        };
      });
      final info = await BoxVpnClient().getAppInfo('ru.fourpda.client');
      expect(info, isNotNull);
      expect(info!.appName, '4PDA');
      expect(info.isSystem, isFalse);
      expect(info.icon, isNull);
    });

    test('timeout → TimeoutException, НЕ null', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return {'notFound': true};
      });
      await expectLater(
        BoxVpnClient().getAppInfo('com.slow.app',
            timeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('PlatformException пробрасывается (retryable)', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'APP_INFO_ERROR', message: 'boom');
      });
      await expectLater(
        BoxVpnClient().getAppInfo('com.any.app'),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('BoxVpnClient.isForeignVpnActive', () {
    test('returns native true', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      final r = await BoxVpnClient().isForeignVpnActive();
      expect(r, isTrue);
      expect(calls.single.method, equals('isForeignVpnActive'));
    });

    test('returns native false', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => false);
      expect(await BoxVpnClient().isForeignVpnActive(), isFalse);
    });

    test('null native answer → false (does not block start)', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await BoxVpnClient().isForeignVpnActive(), isFalse);
    });
  });

  // §207 — pprof-снимки через единый native-метод `pprofProfile`
  // (Dart передаёт готовый pathAndQuery).
  group('BoxVpnClient.pprof (§207)', () {
    test('pprofRaw passes pathAndQuery verbatim to the native call', () async {
      late MethodCall captured;
      messenger.setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return Uint8List.fromList([1, 2, 3]);
      });
      final bytes = await BoxVpnClient().pprofRaw('heap?gc=1');
      expect(captured.method, 'pprofProfile');
      expect(captured.arguments, {'pathAndQuery': 'heap?gc=1'});
      expect(bytes, [1, 2, 3]);
    });

    test('dumpGoroutines requests goroutine?debug=2 and decodes text',
        () async {
      late MethodCall captured;
      messenger.setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return Uint8List.fromList('goroutine 1 [running]:'.codeUnits);
      });
      final text = await BoxVpnClient().dumpGoroutines();
      expect(captured.arguments['pathAndQuery'], 'goroutine?debug=2');
      expect(text, 'goroutine 1 [running]:');
    });

    test('dumpGoroutines decodes UTF-8 bytes correctly (not Latin-1)',
        () async {
      // Multi-byte UTF-8 (Cyrillic «тест») would be mojibake under
      // String.fromCharCodes; utf8.decode round-trips it.
      final utf8Bytes = Uint8List.fromList(utf8.encode('goroutine тест ✓'));
      messenger.setMockMethodCallHandler(channel, (call) async => utf8Bytes);
      final text = await BoxVpnClient().dumpGoroutines();
      expect(text, 'goroutine тест ✓');
    });

    test('dumpGoroutines NEVER throws — PlatformException → fallback text',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'PPROF_FAILED', message: 'port busy');
      });
      final text = await BoxVpnClient().dumpGoroutines();
      expect(text, contains('unavailable'));
      expect(text, contains('port busy'));
    });

    test('captureCpuProfile maps durationMs→seconds (clamped) into pathAndQuery',
        () async {
      late MethodCall captured;
      messenger.setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return Uint8List(0);
      });
      await BoxVpnClient().captureCpuProfile(durationMs: 10000);
      expect(captured.arguments['pathAndQuery'], 'profile?seconds=10');

      // durationMs below 1s clamps to 1 (pprof requires seconds>=1).
      await BoxVpnClient().captureCpuProfile(durationMs: 200);
      expect(captured.arguments['pathAndQuery'], 'profile?seconds=1');
    });

    test('captureCpuProfile propagates PlatformException (surfaced in UI)',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'PPROF_FAILED', message: 'boom');
      });
      await expectLater(
        BoxVpnClient().captureCpuProfile(),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  /// §276 — pull-путь (`getVpnStatus`) на resume. Broadcast'ятся только
  /// переходы, поэтому UI, вернувшийся из фона после перехвата слота, узнаёт о
  /// revoke только отсюда. Native отдаёт map; голая строка — старый контракт.
  group('getVpnStatus', () {
    test('map со Stopped + revoked → revoked (перехват пережил фон)', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return <String, Object>{'status': 'Stopped', 'revoked': true};
      });
      expect(await BoxVpnClient().getVpnStatus(), TunnelStatus.revoked);
    });

    test('map со Stopped без флага → disconnected', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return <String, Object>{'status': 'Stopped', 'revoked': false};
      });
      expect(await BoxVpnClient().getVpnStatus(), TunnelStatus.disconnected);
    });

    test('map со Started → connected', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return <String, Object>{'status': 'Started', 'revoked': false};
      });
      expect(await BoxVpnClient().getVpnStatus(), TunnelStatus.connected);
    });

    test('голая строка от старого native → парсится (совместимость)', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => 'Started');
      expect(await BoxVpnClient().getVpnStatus(), TunnelStatus.connected);
    });

    test('null/timeout → disconnected (UI не залипает)', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await BoxVpnClient().getVpnStatus(), TunnelStatus.disconnected);
    });
  });
}
