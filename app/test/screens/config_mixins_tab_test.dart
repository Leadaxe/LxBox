// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/mixin.dart';
import 'package:lxbox/models/validation.dart';
import 'package:lxbox/screens/config_screen.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'real_io_pump.dart';

// §704 §5 — экран Config: вкладки Config | Mixins, список миксинов с
// тумблером; тумблер пишет в хранилище сразу и запускает пересборку.

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
  @override
  Future<String?> getTemporaryPath() async => '$tempRoot/tmp';
}

/// Шов: пересборка без настоящей сборки — счётчик вызовов и отказ
/// миксина, как его даёт `FatalValidationException`.
class _FakeSub extends SubscriptionController {
  int generateCalls = 0;
  List<ValidationIssue> issues = const [];

  @override
  List<ValidationIssue> get lastFatalIssues => issues;

  @override
  Future<String?> generateConfig() async {
    generateCalls++;
    notifyListeners();
    return null;
  }
}

const _listenerId = 'mixin-listener';
const _dropId = 'mixin-drop';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late _FakeSub sub;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('config_mixins_tab_');
    for (final d in ['docs', 'support', 'tmp']) {
      await Directory('${tempDir.path}/$d').create();
    }
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    sub = _FakeSub();
    await SettingsStorage.setMixins([
      Mixin(
        id: _listenerId,
        name: 'DNS listener for Rethink',
        target: 'inbounds',
        op: 'append',
        value: const {'type': 'direct', 'tag': 'dns-in'},
      ),
      Mixin(
        id: _dropId,
        target: 'route.rules[rule_set=Ads]',
        op: 'remove',
        value: true,
      ),
    ]);
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

  Future<void> pumpUntil(
    WidgetTester tester,
    Future<bool> Function() done, {
    required String what,
  }) async {
    for (var i = 0; i < 400; i++) {
      if (await done()) return;
      await realIoStep(tester, fakeTime: const Duration(milliseconds: 50));
    }
    fail('не дождались: $what');
  }

  Future<HomeController> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final home = HomeController()..debugSetConfigRaw('{"log":{}}');
    addTearDown(home.dispose);
    await tester.pumpWidget(MaterialApp(
      home: ConfigScreen(controller: home, subController: sub),
    ));
    await tester.pump();
    return home;
  }

  testWidgets('tabs Config and Mixins; list shows mixin, issue and toggle',
      (tester) async {
    sub.issues = const [
      MixinIssue(
        mixinId: _dropId,
        name: 'route.rules[rule_set=Ads] → remove',
        target: 'route.rules[rule_set=Ads]',
        reason: 'no match',
      ),
    ];
    await open(tester);
    expect(find.widgetWithText(Tab, 'Config'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Mixins'), findsOneWidget);

    await tester.tap(find.widgetWithText(Tab, 'Mixins'));
    await tester.pump();
    // Анимация смены вкладки (pumpAndSettle не годится: на Config крутится
    // индикатор загрузки).
    await tester.pump(const Duration(milliseconds: 500));
    final row = find.text('DNS listener for Rethink');
    await pumpUntil(tester, () async => row.evaluate().isNotEmpty,
        what: 'строка миксина на вкладке Mixins');
    expect(find.text('inbounds → append'), findsOneWidget);
    // Пустое имя — `target → op` строкой имени.
    expect(find.text('route.rules[rule_set=Ads] → remove'), findsOneWidget);
    expect(find.text('⚠ route.rules[rule_set=Ads]: no match'), findsOneWidget);
    expect(find.byType(Switch), findsNWidgets(2));
    // Save и ⋮ вкладки Config на Mixins скрыты.
    expect(find.widgetWithText(TextButton, 'Save'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('toggle writes storage and rebuilds', (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(Tab, 'Mixins'));
    await tester.pump();
    // Анимация смены вкладки (pumpAndSettle не годится: на Config крутится
    // индикатор загрузки).
    await tester.pump(const Duration(milliseconds: 500));
    final switches = find.byType(Switch);
    await pumpUntil(tester, () async => switches.evaluate().length == 2,
        what: 'тумблеры миксинов');

    await tester.tap(switches.first);
    await tester.pump();
    await pumpUntil(tester, () async {
      final stored = await tester.runAsync(SettingsStorage.getMixins);
      return stored != null &&
          stored.firstWhere((m) => m.id == _listenerId).enabled == false;
    }, what: 'миксин выключен в хранилище');
    await pumpUntil(tester, () async => sub.generateCalls > 0,
        what: 'пересборка после тумблера');

    final stored = await tester.runAsync(SettingsStorage.getMixins);
    expect(stored!.map((m) => m.id), [_listenerId, _dropId]);
    expect(stored.last.enabled, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
