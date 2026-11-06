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
import 'package:lxbox/screens/dns_settings_screen/widgets/merged_server_tile.dart';
import 'package:lxbox/screens/dns_settings_tab.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/template_loader.dart';
import 'package:lxbox/widgets/reorder_grab_strip.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../../parser/engine_test_setup.dart';

// §710 — вкладка DNS: серверы переставляются перетаскиванием за полосу
// слева, порядок тайлов и сохранённый список `dns.servers` — новый.

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
    tempDir = await Directory.systemTemp.createTemp('dns_servers_reorder_');
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
      home: Scaffold(
        body: DnsSettingsTab(subController: sub, homeController: home),
      ),
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

  List<String> tileTags(WidgetTester tester) => [
        for (final e in find.byType(MergedServerTile).evaluate())
          (e.widget as MergedServerTile).entry.tag,
      ];

  Finder serverStrips() => find.descendant(
      of: find.byType(MergedServerTile),
      matching: find.byType(ReorderGrabStrip));

  testWidgets('3-й сервер на 1-е место: тайлы и сохранённый список',
      (tester) async {
    await openScreen(tester);
    final before = tileTags(tester);
    expect(before.length, greaterThanOrEqualTo(3));
    expect(serverStrips().evaluate().length, before.length);

    SettingsStorage.configDirty = false;
    final start = tester.getCenter(serverStrips().at(2));
    final end = tester.getCenter(serverStrips().at(0));
    final dy = end.dy - start.dy - 30;
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, dy / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    await settle(tester);

    final expected = [before[2], before[0], before[1], ...before.skip(3)];
    expect(tileTags(tester), expected);
    expect(SettingsStorage.configDirty, isTrue);
    final saved = await tester.runAsync(SettingsStorage.getDnsServers);
    final savedTags = [
      for (final s in saved!)
        if (expected.contains(s.tag)) s.tag,
    ];
    expect(savedTags, expected);
    await close(tester);
  });
}
