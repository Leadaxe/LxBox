import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/app_settings_screen/widgets/general_tab.dart';
import 'package:lxbox/services/settings_storage.dart';

// §707 итер. 8 — список кнопок уведомления VPN на вкладке General: по
// умолчанию все включены, переключатель сообщает свою кнопку и значение.
// §707 итер. 9 — значения живут в native_prefs (`notification_*`), вкладка
// читает и пишет через SettingsStorage.

void main() {
  Future<void> pump(
    WidgetTester tester, {
    Map<String, bool> buttons = const {},
    void Function(String, bool)? onChanged,
  }) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GeneralTab(
            loaded: true,
            autoStart: false,
            autoCheckUpdates: false,
            autoPing: false,
            haptic: false,
            autoReloadOnChange: false,
            padding: EdgeInsets.zero,
            onAutoStartChanged: (_) {},
            onAutoCheckUpdatesChanged: (_) {},
            onAutoPingChanged: (_) {},
            onHapticChanged: (_) {},
            onAutoReloadOnChangeChanged: (_) {},
            onAddQuickSettingsTile: () {},
            onOpenBackup: () {},
            region: 'none',
            detectedRegion: '',
            onEditRegion: () {},
            notificationButtons: buttons,
            onNotificationButtonChanged: onChanged,
          ),
        ),
      ),
    );
  }

  SwitchListTile row(WidgetTester tester, String button) =>
      tester.widget<SwitchListTile>(
        find.byKey(ValueKey('notification-button-$button')),
      );

  testWidgets('no stored value: all three on', (tester) async {
    await pump(tester);
    for (final b in ['stop', 'restart', 'send']) {
      expect(row(tester, b).value, isTrue, reason: b);
    }
  });

  testWidgets('stored off is shown off; tap reports button and value', (
    tester,
  ) async {
    final calls = <(String, bool)>[];
    await pump(
      tester,
      buttons: const {'restart': false},
      onChanged: (b, v) => calls.add((b, v)),
    );
    expect(row(tester, 'restart').value, isFalse);
    expect(row(tester, 'stop').value, isTrue);

    await tester.tap(find.byKey(const ValueKey('notification-button-restart')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notification-button-send')));
    await tester.pump();
    expect(calls, [('restart', true), ('send', false)]);
  });

  group('§707 итер. 9 — хранилище', () {
    late Directory tmp;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const methodsChannel = MethodChannel('com.leadaxe.lxbox/methods');
    final calls = <MethodCall>[];

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('lxbox_general_tab_707_');
      calls.clear();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pathChannel, (call) async => tmp.path);
      messenger.setMockMethodCallHandler(methodsChannel, (call) async {
        calls.add(call);
        return true;
      });
      SettingsStorage.resetCacheForTesting();
    });

    tearDown(() async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(methodsChannel, null);
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    testWidgets('по умолчанию все включены; запись — ключ native_prefs',
        (tester) async {
      await tester.runAsync(() async {
        expect(await loadNotificationButtons(),
            {'stop': true, 'restart': true, 'send': true});
        await saveNotificationButton('send', false);
        expect(await loadNotificationButtons(),
            {'stop': true, 'restart': true, 'send': false});
        final f = File('${tmp.path}/lxbox_settings.json');
        final data = jsonDecode(await f.readAsString()) as Map;
        expect((data['native_prefs'] as Map)['notification_send'], false);
        expect(
            calls
                .where((c) => c.method == 'setNotificationSend')
                .single
                .arguments,
            {'enabled': false});
      });
    });
  });
}
