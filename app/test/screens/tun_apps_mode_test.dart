import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/screens/tun_apps_tab.dart';
import 'package:lxbox/services/app_info_cache.dart';
import 'package:lxbox/services/settings_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const native = MethodChannel('com.leadaxe.lxbox/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lxbox_tun_apps_ui_');
    messenger.setMockMethodCallHandler(paths, (_) async => tmp.path);
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'getAppInfo') {
        return {'packageName': 'com.example', 'appName': 'Example'};
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
    AppInfoCache.resetForTest();
    await SettingsStorage.setTunApps(
      const TunAppsConfig(mode: 'deny', packages: ['com.example']),
      flush: false,
    );
  });

  tearDown(() async {
    SettingsStorage.resetCacheForTesting();
    AppInfoCache.resetForTest();
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(native, null);
    await tmp.delete(recursive: true);
  });

  testWidgets('selecting direct preserves apps and marks the config dirty', (
    tester,
  ) async {
    final home = HomeController();
    final subscriptions = SubscriptionController();
    addTearDown(home.dispose);
    addTearDown(subscriptions.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TunAppsTab(homeController: home, subController: subscriptions),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .byWidgetPredicate(
            (w) => w is DropdownMenuItem<String> && w.value == 'direct',
          )
          .last,
    );
    await tester.pumpAndSettle();

    expect((await SettingsStorage.getTunApps()).toJson(), {
      'mode': 'direct',
      'packages': ['com.example'],
    });
    expect(subscriptions.configDirty, isTrue);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => SettingsStorage.flushToDisk());
    await tester.pumpAndSettle();
  });
}
