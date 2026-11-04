import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/main.dart' show ThemeNotifier;
import 'package:lxbox/services/settings_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// §707 итер. 9 — кнопки уведомления (`notification_stop|restart|send`) и
/// тема (`app_theme_mode`) в секции native_prefs: дефолты, write-through
/// кнопок в зеркало, тема только в JSON, бэкап-блок, перенос темы из
/// SharedPreferences.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const methodsChannel = MethodChannel('com.leadaxe.lxbox/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final nativeCalls = <MethodCall>[];
  final native = <String, bool>{};

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lxbox_native_prefs_707_');
    nativeCalls.clear();
    native.clear();
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(methodsChannel, (call) async {
      nativeCalls.add(call);
      final m = call.method;
      if (m.startsWith('setNotification')) {
        native[m.substring(3)] = (call.arguments as Map)['enabled'] as bool;
        return true;
      }
      if (m.startsWith('getNotification')) return native[m.substring(3)] ?? true;
      switch (m) {
        case 'getMemoryLimit':
          return 'auto';
        case 'getBackgroundMode':
          return 'never';
        case 'getAutoStart':
        case 'getKeepOnExit':
        case 'getCoreLogsEnabled':
        case 'getCoreLogsVerbose':
        case 'getAllowBypass':
        case 'getAutoRedirect':
          return false;
        default:
          return null;
      }
    });
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(methodsChannel, null);
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<void> seedFile(Map<String, dynamic> data) async {
    await File('${tmp.path}/lxbox_settings.json').writeAsString(jsonEncode(data));
    SettingsStorage.resetCacheForTesting();
  }

  Future<Map<String, dynamic>> section() async {
    final f = File('${tmp.path}/lxbox_settings.json');
    final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    return data['native_prefs'] as Map<String, dynamic>;
  }

  const buttons = [
    NativePrefsKeys.notificationStop,
    NativePrefsKeys.notificationRestart,
    NativePrefsKeys.notificationSend,
  ];

  group('кнопки уведомления', () {
    test('по умолчанию все включены', () async {
      for (final k in buttons) {
        expect(await SettingsStorage.getNativeBool(k), isTrue, reason: k);
      }
    });

    test('write-through: JSON + зеркало своим каналом', () async {
      await SettingsStorage.setNativeBool(
          NativePrefsKeys.notificationRestart, false);
      expect((await section())['notification_restart'], false);
      final set = nativeCalls.where((c) => c.method == 'setNotificationRestart');
      expect(set.single.arguments, {'enabled': false});
      expect(
          await SettingsStorage.getNativeBool(
              NativePrefsKeys.notificationRestart),
          isFalse);
    });

    test('старт: JSON перезаливает расходящееся зеркало', () async {
      await seedFile({
        'native_prefs': {'notification_send': false, 'notification_stop': true},
      });
      await SettingsStorage.bootstrapAndSyncNativePrefs();
      expect(native['NotificationSend'], false);
      // Совпадающее значение не переписывается.
      expect(nativeCalls.where((c) => c.method == 'setNotificationStop'),
          isEmpty);
    });

    test('бэкап-блок: три ключа с дефолтами, применение', () async {
      final block = await SettingsStorage.exportNativePrefsBackup();
      for (final k in buttons) {
        expect(block[k], true, reason: k);
      }
      final n = await SettingsStorage.applyNativePrefsBackup(
          {'notification_stop': false});
      expect(n, 1);
      expect(await SettingsStorage.getNativeBool(NativePrefsKeys.notificationStop),
          isFalse);
      expect(native['NotificationStop'], false);
    });
  });

  group('тема app_theme_mode', () {
    test('по умолчанию system; запись только в JSON', () async {
      expect(await SettingsStorage.getNativeThemeMode(), 'system');
      expect(await SettingsStorage.hasNativeThemeMode(), isFalse);
      await SettingsStorage.setNativeThemeMode('dark');
      expect((await section())['app_theme_mode'], 'dark');
      expect(await SettingsStorage.hasNativeThemeMode(), isTrue);
      expect(nativeCalls.where((c) => c.method.toLowerCase().contains('theme')),
          isEmpty);
    });

    test('мусор → system; бэкап-блок несёт тему', () async {
      await seedFile({
        'native_prefs': {'app_theme_mode': 'neon'},
      });
      expect(await SettingsStorage.getNativeThemeMode(), 'system');
      final n = await SettingsStorage.applyNativePrefsBackup(
          {'app_theme_mode': 'light'});
      expect(n, 1);
      expect(await SettingsStorage.getNativeThemeMode(), 'light');
      expect((await SettingsStorage.exportNativePrefsBackup())['app_theme_mode'],
          'light');
    });

    test('перенос из SharedPreferences: значение переезжает, ключ удаляется',
        () async {
      SharedPreferences.setMockInitialValues({'app_theme_mode': 'dark'});
      final t = ThemeNotifier();
      await t.load();
      expect(t.mode, ThemeMode.dark);
      expect(await SettingsStorage.getNativeThemeMode(), 'dark');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('app_theme_mode'), isFalse);
    });

    test('ключ уже в хранилище: SharedPreferences не трогаются', () async {
      await seedFile({
        'native_prefs': {'app_theme_mode': 'light'},
      });
      SharedPreferences.setMockInitialValues({'app_theme_mode': 'dark'});
      final t = ThemeNotifier();
      await t.load();
      expect(t.mode, ThemeMode.light);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_theme_mode'), 'dark');
    });

    test('хук: импорт бэкапа и пересинк перечитывают тему без перезапуска',
        () async {
      SharedPreferences.setMockInitialValues({});
      final t = ThemeNotifier();
      await t.load();
      expect(t.mode, ThemeMode.system);
      var notified = 0;
      t.addListener(() => notified++);

      final g0 = SettingsStorage.nativePrefsGeneration.value;
      await SettingsStorage.applyNativePrefsBackup({'app_theme_mode': 'dark'});
      expect(SettingsStorage.nativePrefsGeneration.value, g0 + 1);
      await pumpEventQueue();
      expect(t.mode, ThemeMode.dark);
      expect(notified, 1);

      // Смена Workspaces: файл подменён, затем пересинк — тема из нового файла.
      await seedFile({
        'native_prefs': {'app_theme_mode': 'light'},
      });
      await SettingsStorage.bootstrapAndSyncNativePrefs();
      expect(SettingsStorage.nativePrefsGeneration.value, g0 + 2);
      await pumpEventQueue();
      expect(t.mode, ThemeMode.light);
      expect(notified, 2);
    });

    test('setMode пишет в хранилище', () async {
      SharedPreferences.setMockInitialValues({});
      final t = ThemeNotifier();
      await t.load();
      await t.setMode(ThemeMode.light);
      expect(await SettingsStorage.getNativeThemeMode(), 'light');
    });
  });
}
