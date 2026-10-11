// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/screens/home/home_menus.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

class _FakeHome extends HomeController {
  int reloads = 0;

  @override
  Future<void> reloadPingOptions() async => reloads++;
}

// §626 — шторка Ping Settings: с правкой Back и смахивание вниз спрашивают
// общий диалог Unsaved changes; без правок шторка закрывается.
void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('ping_unsaved_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  bool sheetOpen() => find.text('Ping Settings').evaluate().isNotEmpty;
  Finder unsaved() => find.text('Unsaved changes');

  /// Ждать условие, давая реальному IO (шаблон, настройки) идти.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<_FakeHome> open(WidgetTester tester) async {
    final home = _FakeHome();
    addTearDown(home.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: TextButton(
              onPressed: () => showPingSettings(context, home),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester, sheetOpen);
    expect(sheetOpen(), isTrue);
    return home;
  }

  Future<void> editTimeout(WidgetTester tester) async {
    await tester.enterText(
        find.widgetWithText(TextField, 'Timeout (ms)'), '1234');
    await tester.pump();
  }

  Future<void> swipe(WidgetTester tester) async {
    await tester.fling(find.text('Ping Settings'), const Offset(0, 300), 1500);
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
        of: find.ancestor(of: unsaved(), matching: find.byType(AlertDialog)),
        matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  testWidgets('без правок — смахивание закрывает без диалога', (tester) async {
    await open(tester);
    await swipe(tester);
    expect(unsaved(), findsNothing);
    expect(sheetOpen(), isFalse);
  });

  testWidgets('правка → смахивание → диалог; Discard закрывает без записи',
      (tester) async {
    final home = await open(tester);
    await editTimeout(tester);
    await swipe(tester);
    expect(unsaved(), findsOneWidget);
    await choose(tester, 'Discard');
    expect(sheetOpen(), isFalse);
    expect(home.reloads, 0);
  });

  testWidgets('Keep — шторка остаётся, правка на месте', (tester) async {
    await open(tester);
    await editTimeout(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await choose(tester, 'Keep');
    expect(sheetOpen(), isTrue);
    expect(find.widgetWithText(TextField, '1234'), findsOneWidget);
  });

  testWidgets('Save — записано и закрыто', (tester) async {
    final home = await open(tester);
    await editTimeout(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await choose(tester, 'Save');
    await settle(tester, () => !sheetOpen());
    expect(sheetOpen(), isFalse);
    expect(home.reloads, 1);
  });
}
