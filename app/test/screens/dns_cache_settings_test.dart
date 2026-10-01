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
import 'package:lxbox/screens/dns_settings_screen.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/template_loader.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

// §580 — экран DNS: три настройки кэша видны, изменение помечает конфиг,
// размер вне границ не сохраняется.

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
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  late Directory tempDir;
  late SubscriptionController sub;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dns_cache_settings_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    sub = SubscriptionController();
    await TemplateLoader.load();
    await SettingsStorage.getAllVars();
  });

  tearDown(() async {
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    SettingsStorage.resetCacheForTesting();
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  Future<void> openScreen(WidgetTester tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1.0;
    final home = HomeController();
    addTearDown(home.dispose);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: LocaleController.supportedLocales,
      home: DnsSettingsScreen(subController: sub, homeController: home),
    ));
    // Загрузка экрана читает шаблон и хранилище — настоящая зона.
    for (var i = 0;
        i < 50 && find.byKey(const ValueKey('dns_optimistic')).evaluate().isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  /// Экран закрывается, таймеры экрана прокручиваются до конца теста.
  Future<void> close(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  testWidgets('три настройки видны со значениями по умолчанию',
      (tester) async {
    await openScreen(tester);
    expect(find.byKey(const ValueKey('dns_cache_capacity')), findsOneWidget);
    expect(find.byKey(const ValueKey('dns_optimistic')), findsOneWidget);
    expect(find.byKey(const ValueKey('dns_store_cache')), findsOneWidget);
    expect(find.text('4000'), findsOneWidget);
    expect(
        tester
            .widget<SwitchListTile>(find.byKey(const ValueKey('dns_optimistic')))
            .value,
        isTrue);
    expect(
        tester
            .widget<SwitchListTile>(find.byKey(const ValueKey('dns_store_cache')))
            .value,
        isTrue);
    await close(tester);
  });

  testWidgets('переключатель помечает конфиг и сохраняется', (tester) async {
    await openScreen(tester);
    SettingsStorage.configDirty = false;
    await tester.tap(find.byKey(const ValueKey('dns_optimistic')));
    await tester.pump();
    await settle(tester);
    expect(SettingsStorage.configDirty, isTrue);
    expect(
        await tester.runAsync(
            () => SettingsStorage.getVar('dns_optimistic', '')),
        'false');
    await close(tester);
  });

  testWidgets('размер: в границах сохраняется, вне границ — нет',
      (tester) async {
    await openScreen(tester);
    final field = find.byKey(const ValueKey('dns_cache_capacity'));

    SettingsStorage.configDirty = false;
    await tester.enterText(field, '70000');
    await tester.pump();
    await settle(tester);
    expect(SettingsStorage.configDirty, isFalse);
    expect(
        await tester.runAsync(
            () => SettingsStorage.getVar('dns_cache_capacity', '')),
        isNot('70000'));

    await tester.enterText(field, '8192');
    await tester.pump();
    await settle(tester);
    expect(SettingsStorage.configDirty, isTrue);
    expect(
        await tester.runAsync(
            () => SettingsStorage.getVar('dns_cache_capacity', '')),
        '8192');
    await close(tester);
  });
}
