// ignore_for_file: depend_on_referenced_packages
@Timeout(Duration(seconds: 180))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/screens/routing_screen.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/template_loader.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

// §655 И2 — вкладка DNS пишет `custom_rules` мимо буферов Routing. После
// ухода с неё Routing перечитывает буферы, и правка на Rules не затирает
// правку вкладки DNS: в хранилище оба изменения.

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

const _ruleId = 'rule-655';

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
    tempDir = await Directory.systemTemp.createTemp('routing_dns_tab_');
    for (final d in ['docs', 'support', 'tmp']) {
      await Directory('${tempDir.path}/$d').create();
    }
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    sub = SubscriptionController();
    await TemplateLoader.load();
    await SettingsStorage.getAllVars();
    // Правило с DNS-опцией: на вкладке DNS — строка с её свитчем, на Rules —
    // тайл со свитчем правила.
    await SettingsStorage.saveCustomRules([
      CustomRuleInline(
        id: _ruleId,
        name: 'Sync check',
        domainSuffixes: const ['example.org'],
        dns: const RuleDns(enabled: true, serverTag: 'google_doh'),
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

  /// Прокачать реальную зону (хранилище, шаблон) до выполнения условия.
  Future<void> pumpUntil(
    WidgetTester tester,
    Future<bool> Function() done, {
    required String what,
  }) async {
    for (var i = 0; i < 400; i++) {
      if (await done()) return;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    fail('не дождались: $what');
  }

  Future<CustomRule> storedRule(WidgetTester tester) async {
    final rules = await tester.runAsync(SettingsStorage.getCustomRules);
    return rules!.firstWhere((r) => r.id == _ruleId);
  }

  testWidgets('правка на DNS, затем на Rules — в хранилище обе',
      (tester) async {
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
      home: RoutingScreen(
        subController: sub,
        homeController: home,
        initialTab: RoutingTab.dns,
      ),
    ));

    // 1. Вкладка DNS: свитч DNS-опции правила → `custom_rules` напрямую.
    final mirror = find.byKey(const ValueKey('dns-mirror-$_ruleId'));
    await pumpUntil(tester, () async => mirror.evaluate().isNotEmpty,
        what: 'строка DNS-опции правила на вкладке DNS');
    await tester.tap(
        find.descendant(of: mirror, matching: find.byType(Switch)));
    await tester.pump();
    await pumpUntil(
        tester, () async => !(await storedRule(tester)).dnsMirrorActive,
        what: 'DNS-опция снята в хранилище');

    // 2. Уход на Rules: Routing перечитывает буфер — чип «DNS» у правила
    //    пропадает (DNS-опция больше не активна).
    await tester.tap(find.widgetWithText(Tab, 'Rules'));
    await tester.pump();
    final tile = find.byKey(const ValueKey(_ruleId));
    await pumpUntil(
        tester,
        () async =>
            tile.evaluate().isNotEmpty &&
            find
                .descendant(of: tile, matching: find.text('DNS'))
                .evaluate()
                .isEmpty,
        what: 'буфер Routing перечитан после ухода с DNS');

    // 3. Правка на Rules: выключить правило (staging буфера Routing).
    await tester.tap(find.descendant(of: tile, matching: find.byType(Switch)));
    await tester.pump();
    await pumpUntil(
        tester, () async => !(await storedRule(tester)).enabled,
        what: 'правило выключено в хранилище');

    final rule = await storedRule(tester);
    expect(rule.enabled, isFalse);
    expect(rule.dns?.enabled, isFalse,
        reason: 'staging Rules не должен вернуть DNS-опцию из старого буфера');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
