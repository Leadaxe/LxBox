// ignore_for_file: depend_on_referenced_packages
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/screens/tun_apps_tab.dart';
import 'package:lxbox/services/app_info_cache.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// 693 итер. 3 — вкладка Tunnel apps запрашивает данные и иконки только у
// видимых строк, а пересбор по AppInfoCache.revision не порождает повторных
// запросов (в том числе у приложений, для которых иконка пустая).

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const n = 200;
  final packages = [
    for (var i = 0; i < n; i++) 'com.app${i.toString().padLeft(3, '0')}',
  ];

  late Directory tempDir;
  late List<String> requested; // pkg каждого getAppInfo / getAppIcon

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tun_apps_lazy_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    AppInfoCache.resetForTest();
    AppInfoCache.retryDelays = const [];
    requested = [];
    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'getAppIcon':
          requested.add((call.arguments as Map)['packageName'] as String);
          return ''; // иконки нет — плитка не должна просить её по кругу
        case 'getAppInfo':
          final pkg = (call.arguments as Map)['packageName'] as String;
          requested.add(pkg);
          return {'packageName': pkg, 'appName': pkg, 'isSystemApp': false};
        case 'getInstalledApps':
          return <dynamic>[
            for (final p in packages)
              {'packageName': p, 'appName': p, 'isSystem': false},
          ];
      }
      return null;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(methods, null);
    AppInfoCache.resetForTest();
    SettingsStorage.resetCacheForTesting();
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  testWidgets('200 saved apps: only visible rows are requested, no re-requests',
      (tester) async {
    await tester.runAsync(() => SettingsStorage.setTunApps(
        TunAppsConfig(mode: 'allow', packages: packages)));

    final home = HomeController();
    addTearDown(home.dispose);
    final sub = SubscriptionController();

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: LocaleController.supportedLocales,
      home: Scaffold(body: TunAppsTab(homeController: home, subController: sub)),
    ));
    for (var i = 0; i < 50 && find.text('com.app000').evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.text('com.app000'), findsWidgets);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final first = requested.toSet();
    expect(first, isNotEmpty);
    expect(first.length, lessThan(n ~/ 4),
        reason: 'запрошены только видимые строки, не все $n');
    expect(first, isNot(contains('com.app199')));

    // Пересбор по revision — новых запросов нет.
    final before = requested.length;
    for (var i = 0; i < 3; i++) {
      AppInfoCache.revision.value = AppInfoCache.revision.value + 1;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(requested.length, before);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
