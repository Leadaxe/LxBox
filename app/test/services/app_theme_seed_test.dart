import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/main.dart' show ThemeNotifier;
import 'package:lxbox/services/app_theme_seed.dart';
import 'package:lxbox/services/platform_channels.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §735 — опция «System colors»: seed темы из системной палитры только при
/// включённой опции и доступной палитре; флаг в `vars.dynamic_color`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const accent = Color(0xFF00897B);

  group('appThemeSeed', () {
    test('по умолчанию — фирменный индиго', () {
      expect(appThemeSeed(dynamicColor: false, systemAccent: null),
          kAppSeedColor);
      expect(appThemeSeed(dynamicColor: false, systemAccent: accent),
          kAppSeedColor);
    });

    test('опция включена, палитры нет (Android < 12, TV) — индиго', () {
      expect(appThemeSeed(dynamicColor: true, systemAccent: null),
          kAppSeedColor);
    });

    test('опция включена, палитра есть — акцент системы', () {
      expect(appThemeSeed(dynamicColor: true, systemAccent: accent), accent);
    });
  });

  group('ThemeNotifier + хранилище', () {
    late Directory tmp;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const utilsChannel = MethodChannel(PlatformChannels.utils);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    int? platformAccent;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('lxbox_dynamic_color_735_');
      platformAccent = 0xFF00897B;
      messenger.setMockMethodCallHandler(pathChannel, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory' ||
            call.method == 'getApplicationDocumentsPath') {
          return tmp.path;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(utilsChannel, (call) async {
        if (call.method == 'systemAccentColor') return platformAccent;
        return null;
      });
      SettingsStorage.resetCacheForTesting();
    });

    tearDown(() async {
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(utilsChannel, null);
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('дефолт: выключено, переключатель доступен, seed индиго', () async {
      expect(await SettingsStorage.getDynamicColor(), isFalse);
      final n = ThemeNotifier();
      await n.load();
      expect(n.dynamicColor, isFalse);
      expect(n.dynamicColorAvailable, isTrue);
      expect(n.seed, kAppSeedColor);
    });

    test('включение пишет var и меняет seed; переживает перечитывание',
        () async {
      final n = ThemeNotifier();
      await n.load();
      await n.setDynamicColor(true);
      expect(n.seed, accent);
      expect(await SettingsStorage.getVar('dynamic_color', ''), 'true');

      SettingsStorage.resetCacheForTesting();
      final again = ThemeNotifier();
      await again.load();
      expect(again.dynamicColor, isTrue);
      expect(again.seed, accent);
    });

    test('палитры нет — переключатель скрыт, seed индиго даже при true',
        () async {
      platformAccent = null;
      await SettingsStorage.setDynamicColor(true);
      final n = ThemeNotifier();
      await n.load();
      expect(n.dynamicColorAvailable, isFalse);
      expect(n.seed, kAppSeedColor);
    });

    test('dynamic_color — app-флаг, разрешён при импорте снимка', () {
      expect(SettingsStorage.allowedVarKeys(const []), contains('dynamic_color'));
    });
  });
}
