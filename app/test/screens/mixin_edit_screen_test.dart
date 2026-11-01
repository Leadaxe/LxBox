// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/screens/mixin_edit_screen.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// §704 §5 — форма миксина: статус Target на фикстурном конфиге, Save
// неактивна при «no match», подсказки по курсору после `outbounds[`.

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late SubscriptionController sub;
  late Map<String, dynamic> config;

  setUpAll(() {
    config = jsonDecode(
      File('test/fixtures/storage/golden/rich_v0.config.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mixin_edit_');
    for (final d in ['docs', 'support', 'tmp']) {
      await Directory('${tempDir.path}/$d').create();
    }
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    sub = SubscriptionController()..debugSetLastConfigBeforeMixins(config);
  });

  tearDown(() async {
    sub.dispose();
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: MixinEditScreen(mixins: const [], subController: sub),
    ));
    await tester.pump();
  }

  Finder target() => find.byKey(const ValueKey('mixin-target'));
  String status(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('mixin-target-status')))
      .data!;
  TextButton saveButton(WidgetTester tester) =>
      tester.widget<TextButton>(find.widgetWithText(TextButton, 'Save'));

  testWidgets('append: list target ✓ 1 match, element ✗', (tester) async {
    await open(tester);
    // Действие по умолчанию — append.
    await tester.enterText(target(), 'route.rules[action=hijack-dns]');
    await tester.pump();
    // append на элемент-объект — не список.
    expect(status(tester), '✗ needs a single list');

    await tester.enterText(target(), 'route.rules');
    await tester.pump();
    expect(status(tester), '✓ 1 match');
  });

  testWidgets('before on hijack-dns rule: ✓ 1 match, Save after Value',
      (tester) async {
    await open(tester);
    await tester.tap(find.text('append'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('before').last);
    await tester.pumpAndSettle();
    await tester.enterText(target(), 'route.rules[action=hijack-dns]');
    await tester.pump();
    expect(status(tester), '✓ 1 match');
    // Value пуст — Save неактивна.
    expect(saveButton(tester).onPressed, isNull);
  });

  testWidgets('no match: ✗ no match, Save disabled', (tester) async {
    await open(tester);
    await tester.enterText(target(), 'outbounds[tag=nope]');
    await tester.pump();
    expect(status(tester), '✗ no match');
    expect(saveButton(tester).onPressed, isNull);
  });

  testWidgets('suggestions after outbounds[', (tester) async {
    await open(tester);
    await tester.tap(target());
    await tester.enterText(target(), 'outbounds[');
    await tester.pump();
    expect(find.text('tag='), findsOneWidget);
    expect(find.text('type='), findsOneWidget);

    await tester.tap(find.text('tag='));
    await tester.pump();
    final field = tester.widget<TextField>(target());
    expect(field.controller!.text, 'outbounds[tag=');
    expect(find.text('PR DE-1'), findsOneWidget);
  });
}
