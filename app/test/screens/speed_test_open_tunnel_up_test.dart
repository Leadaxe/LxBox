// ignore_for_file: depend_on_referenced_packages
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/screens/speed_test_screen.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// §666 — Speed Test открывается при поднятом туннеле: первый кадр строится
// до загрузки шаблона с пустым списком серверов, и подпись маршрута (§634)
// индексировала `_servers[0]` → RangeError. Тест: первый кадр без
// исключения, после загрузки серверы есть и Start активна.

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

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('speed_test_open_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
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

  testWidgets('opens with tunnel up: no RangeError on the first frame',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;

    final home = HomeController();
    addTearDown(home.dispose);
    home.debugSeedNodeState(group: 'proxy', activeNode: 'n1', tunnelUp: true);
    expect(home.state.tunnelUp, isTrue);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: LocaleController.supportedLocales,
      home: SpeedTestScreen(homeController: home),
    ));
    // Первый кадр — до `_loadConfig`, серверов ещё нет.
    expect(tester.takeException(), isNull);
    expect(find.text('Speed Test'), findsOneWidget);

    // Шаблон читается из assets — настоящая зона.
    for (var i = 0; i < 50 && find.text('Cloudflare').evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
    expect(find.text('Cloudflare'), findsOneWidget);
    final start = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(start.onPressed, isNotNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
