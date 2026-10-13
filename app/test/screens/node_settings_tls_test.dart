// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/screens/node_settings_screen.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

class _Host {
  bool closed = false;
}

// §636 — секция TLS экрана узла: выбор в диалоге пишется сразу, без Save.
void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('node_tls_');
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

  const link = 'vless://u1@h1.example:443?type=ws&security=tls#Alpha';

  /// Ждать условие, давая реальному IO (файлы, изоляты) идти.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<(SubscriptionController, _Host)> open(WidgetTester tester) async {
    final c = SubscriptionController();
    await tester.runAsync(() async {
      await c.init();
      await c.addFromInput(link);
    });
    final host = _Host();
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => NodeSettingsScreen(
                  entry: c.entries.single,
                  index: 0,
                  subController: c,
                ),
              ));
              host.closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(
        tester, () => find.byType(TabBarView).evaluate().isNotEmpty);
    expect(find.byType(TabBarView), findsOneWidget);
    return (c, host);
  }

  // Вертикальный Scrollable вкладки Settings (у TextField и TabBarView —
  // горизонтальные).
  Finder settingsList() => find
      .byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down)
      .first;

  // Строка под нижней панелью экрана не принимает тап: докрутить с запасом.
  Future<void> reveal(WidgetTester tester, Finder row) async {
    await tester.scrollUntilVisible(row, 200, scrollable: settingsList());
    await tester.drag(settingsList(), const Offset(0, -300));
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, String tile, String option) async {
    final row = find.byKey(ValueKey('tls-$tile'));
    await reveal(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('tls-$tile-$option')));
    await tester.pumpAndSettle();
  }

  testWidgets('On / Off / Default пишутся в узловую политику сразу',
      (tester) async {
    final (c, _) = await open(tester);
    expect(c.entries.single.tls.isEmpty, isTrue);

    await pick(tester, 'fragment', 'on');
    await settle(tester, () => c.entries.single.tls.fragment == true);
    expect(c.entries.single.tls.fragment, isTrue);

    await pick(tester, 'mixed_case_sni', 'off');
    await settle(tester, () => c.entries.single.tls.mixedCaseSni == false);
    expect(c.entries.single.tls.mixedCaseSni, isFalse);
    expect(c.entries.single.tls.fragment, isTrue, reason: 'поля независимы');

    await pick(tester, 'fragment', 'default');
    await settle(tester, () => c.entries.single.tls.fragment == null);
    expect(c.entries.single.tls.fragment, isNull);
    expect(c.entries.single.tls.mixedCaseSni, isFalse);
  });

  testWidgets('пауза: негодная не принимается, Use default сбрасывает',
      (tester) async {
    final (c, _) = await open(tester);
    final row = find.byKey(const ValueKey('tls-fallback_delay'));
    await reveal(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('tls-fallback_delay-field'));
    await tester.enterText(field, 'fast');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(c.entries.single.tls.fallbackDelay, isNull);

    await tester.enterText(field, '1s');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester, () => c.entries.single.tls.fallbackDelay == '1s');
    expect(c.entries.single.tls.fallbackDelay, '1s');

    await reveal(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('tls-fallback_delay-default')));
    await settle(tester, () => c.entries.single.tls.fallbackDelay == null);
    expect(c.entries.single.tls.fallbackDelay, isNull);
  });
}
