import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/app_info_cache.dart';

/// §109 — семантика AppInfoCache: «подтверждённый not-found» vs
/// «проверка сорвалась». Регрессия, которую ловим: timeout/ошибка канала
/// кэшировались как null → UI красил установленное приложение
/// «uninstalled, auto-skipped» до конца сессии (field report, 4PDA).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.leadaxe.lxbox/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // 1x1 px PNG — валидный base64 для icon-ветки.
  const kPngB64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
      'DwAChwGA60e6kgAAAABJRU5ErkJggg==';

  var appInfoCalls = 0;
  var iconCalls = 0;
  // Подменяемый ответ getAppInfo; throw из handler'а доедет до Dart как
  // PlatformException — тот же retryable-класс что и native result.error.
  late Object? Function(String pkg) appInfoResponder;

  setUp(() {
    appInfoCalls = 0;
    iconCalls = 0;
    AppInfoCache.resetForTest();
    // Без задержек — retry уходит в microtask-очередь, pump() дожёвывает.
    AppInfoCache.retryDelays = const [
      Duration.zero,
      Duration.zero,
      Duration.zero,
    ];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getAppInfo':
          appInfoCalls++;
          return appInfoResponder(
              (call.arguments as Map)['packageName'] as String);
        case 'getAppIcon':
          iconCalls++;
          return kPngB64;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    AppInfoCache.resetForTest();
  });

  /// Дожёвывает fire-and-forget fetch'и + zero-delay retries.
  Future<void> pump() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Map<String, Object?> meta(String pkg, {String? name}) => {
        'packageName': pkg,
        'appName': name ?? pkg,
        'isSystemApp': false,
      };

  group('подтверждённый not-found', () {
    test('кэшируется, isNotFound=true, повторно не дёргается', () async {
      appInfoResponder = (_) => {'notFound': true};
      AppInfoCache.ensure('com.gone.app');
      await pump();

      expect(AppInfoCache.isNotFound('com.gone.app'), isTrue);
      expect(AppInfoCache.of('com.gone.app'), isNull);
      expect(appInfoCalls, 1);

      AppInfoCache.ensure('com.gone.app'); // no-op по контракту
      await pump();
      expect(appInfoCalls, 1);
    });
  });

  group('установленное приложение', () {
    test('метаданные кэшируются, иконка дотягивается вторым вызовом',
        () async {
      appInfoResponder = (pkg) => meta(pkg, name: '4PDA');
      AppInfoCache.ensure('ru.fourpda.client');
      await pump();

      final info = AppInfoCache.of('ru.fourpda.client');
      expect(info, isNotNull);
      expect(info!.appName, '4PDA');
      expect(info.icon, isNotNull, reason: 'иконка из chained getAppIcon');
      expect(AppInfoCache.isNotFound('ru.fourpda.client'), isFalse);
      expect(appInfoCalls, 1);
      expect(iconCalls, 1);
    });
  });

  group('сорвавшаяся проверка (timeout / ошибка канала)', () {
    test('НЕ помечает not-found и ретраится до успеха', () async {
      var failures = 0;
      appInfoResponder = (pkg) {
        if (failures < 1) {
          failures++;
          throw PlatformException(code: 'APP_INFO_ERROR');
        }
        return meta(pkg);
      };
      AppInfoCache.ensure('com.alive.app');
      await pump();

      expect(AppInfoCache.isNotFound('com.alive.app'), isFalse,
          reason: 'ошибка канала ≠ «не установлено» — суть §109');
      expect(AppInfoCache.of('com.alive.app'), isNotNull);
      expect(appInfoCalls, 2, reason: '1 сорвавшаяся + 1 успешный retry');
    });

    test('после исчерпания ретраев остаётся unknown, не uninstalled',
        () async {
      appInfoResponder = (_) => throw PlatformException(code: 'X');
      AppInfoCache.ensure('com.alive.app');
      await pump();

      expect(appInfoCalls, 1 + AppInfoCache.retryDelays.length);
      expect(AppInfoCache.isNotFound('com.alive.app'), isFalse);
      expect(AppInfoCache.of('com.alive.app'), isNull);
    });

    test('ручной ensure после исчерпания пробует снова', () async {
      appInfoResponder = (_) => throw PlatformException(code: 'X');
      AppInfoCache.ensure('com.alive.app');
      await pump();
      final exhausted = appInfoCalls;

      appInfoResponder = (pkg) => meta(pkg);
      AppInfoCache.ensure('com.alive.app');
      await pump();

      expect(appInfoCalls, exhausted + 1);
      expect(AppInfoCache.of('com.alive.app'), isNotNull);
    });
  });
}
