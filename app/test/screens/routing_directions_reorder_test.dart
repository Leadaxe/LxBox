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
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/screens/routing_screen.dart';
import 'package:lxbox/screens/routing_screen/widgets/routing_group_tile.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/builder/direction_pool_preview.dart';
import 'package:lxbox/services/direction_mutations.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/template_loader.dart';
import 'package:lxbox/widgets/reorder_grab_strip.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

// §673 — вкладка Directions: перестановка drag-handle'ом пишет порядок в
// хранилище тем же bulk-путём, что `POST /directions/reorder`
// (`DirectionMutations.bulkReplace`); сброс в запретную зону (правило 026
// «Other directions — только выше») список не меняет и объясняется SnackBar'ом.

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

  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  late Directory tempDir;
  late SubscriptionController sub;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('routing_dir_reorder_');
    for (final d in ['docs', 'support', 'tmp']) {
      await Directory('${tempDir.path}/$d').create();
    }
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    // Пул превью (§674) — на main, без isolate.
    directionPoolWorkerForTesting = (input) => input.run();
    sub = SubscriptionController();
    await TemplateLoader.load();
    await SettingsStorage.getAllVars();
    await DirectionMutations.bulkReplace(const [
      Direction(tag: 'vpn-1', label: 'Main'),
      Direction(tag: 'vpn-2', label: 'Second'),
      Direction(tag: 'vpn-3', label: 'Third', include: ['vpn-2']),
    ]);
  });

  tearDown(() async {
    directionPoolWorkerForTesting = null;
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
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    fail('не дождались: $what');
  }

  Future<List<String>> storedOrder(WidgetTester tester) async {
    final dirs = await tester.runAsync(SettingsStorage.getDirections);
    return [for (final d in dirs!) d.tag];
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(800, 3000);
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
        initialTab: RoutingTab.directions,
      ),
    ));
    await pumpUntil(
        tester,
        () async => find.byType(ReorderGrabStrip).evaluate().length == 3,
        what: 'три Направления с drag-handle');
    expect(await storedOrder(tester), ['vpn-1', 'vpn-2', 'vpn-3']);
  }

  /// Тянет строку [from] на место строки [to] (с запасом [extra] за неё);
  /// перед отпусканием зовёт [whileDragging].
  Future<void> drag(
    WidgetTester tester,
    int from,
    int to, {
    double extra = 30,
    Future<void> Function()? whileDragging,
  }) async {
    final handles = find.byType(ReorderGrabStrip);
    final start = tester.getCenter(handles.at(from));
    final end = tester.getCenter(handles.at(to));
    final dy = end.dy - start.dy + (end.dy < start.dy ? -extra : extra);
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, dy / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    if (whileDragging != null) await whileDragging();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets(
      'сброс в запретную зону: порядок не меняется, зона подсвечена, '
      'снэкбар называет ссылку', (tester) async {
    await pumpScreen(tester);
    final cs = Theme.of(tester.element(find.byType(RoutingScreen))).colorScheme;
    // «Third» включает «Second» → выше «Second» (и «Main» над ним) нельзя.
    var tinted = 0;
    await drag(tester, 2, 0, whileDragging: () async {
      tinted = find
          .byWidgetPredicate((w) =>
              w is AnimatedContainer &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).color ==
                  cs.error.withValues(alpha: 0.12))
          .evaluate()
          .length;
    });
    expect(tinted, 2);
    expect(find.text('Cannot move: "Third" includes "Second"'), findsOneWidget);
    // Подсветка снята после drop.
    expect(
        find
            .byWidgetPredicate((w) =>
                w is AnimatedContainer &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).color ==
                    cs.error.withValues(alpha: 0.12))
            .evaluate(),
        isEmpty);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    expect(await storedOrder(tester), ['vpn-1', 'vpn-2', 'vpn-3']);
    Finder row(String label) => find.descendant(
        of: find.byType(RoutingDirectionTile), matching: find.text(label));
    expect(tester.getCenter(row('Second')).dy,
        lessThan(tester.getCenter(row('Third')).dy));
    await unmount(tester);
  });

  testWidgets('допустимый сброс пишет порядок в хранилище; vpn-1 двигается',
      (tester) async {
    await pumpScreen(tester);
    // «Main» никто не держит ссылкой → вниз до конца можно.
    await drag(tester, 0, 2);
    await pumpUntil(
        tester,
        () async =>
            (await storedOrder(tester)).join(',') == 'vpn-2,vpn-3,vpn-1',
        what: 'новый порядок в хранилище');
    expect(find.textContaining('Cannot move'), findsNothing);

    // Сборка идёт в новом порядке; ссылка vpn-3 → vpn-2 по-прежнему вверх.
    final dirs = (await tester.runAsync(SettingsStorage.getDirections))!;
    final r = (await tester.runAsync(() => buildConfig(
          lists: const [],
          settings: BuildSettings(directions: dirs),
        )))!;
    final tags = [
      for (final o in (r.config['outbounds'] as List).cast<Map>()) o['tag'],
    ];
    expect(tags.indexOf('vpn-2'), lessThan(tags.indexOf('vpn-3')));
    expect(tags.indexOf('vpn-3'), lessThan(tags.indexOf('vpn-1')));
    expect(r.emitWarnings, isNot(contains(contains('dropped'))));
    await unmount(tester);
  });
}
