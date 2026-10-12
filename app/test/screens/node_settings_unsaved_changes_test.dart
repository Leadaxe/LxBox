// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/screens/node_settings_screen.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';
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

// §626 — настройки узла: Back с несохранённой правкой (поле Tag вкладки
// Settings, текст Source) спрашивает общий диалог Unsaved changes.
void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('node_unsaved_');
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

  Finder tagField() => find.widgetWithText(TextField, 'Tag');
  Finder dialog() => find.byType(AlertDialog);

  Future<void> back(WidgetTester tester) async {
    await tester.pageBack();
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester
        .tap(find.descendant(of: dialog(), matching: find.text(label)));
    await tester.pump();
  }

  testWidgets('без правок — выход без диалога', (tester) async {
    final (_, host) = await open(tester);
    await back(tester);
    expect(dialog(), findsNothing);
    expect(host.closed, isTrue);
  });

  testWidgets('правка Tag → Back → диалог; Discard закрывает без записи',
      (tester) async {
    final (c, host) = await open(tester);
    final original = c.entries.single.list.nodes.single.tag;
    await tester.enterText(tagField(), 'Beta');
    await tester.pump();
    await back(tester);
    expect(dialog(), findsOneWidget);
    await choose(tester, 'Discard');
    await tester.pumpAndSettle();
    expect(host.closed, isTrue);
    expect(c.entries.single.list.nodes.single.tag, original);
  });

  testWidgets('вернул как было — диалога нет', (tester) async {
    final (c, host) = await open(tester);
    await tester.enterText(tagField(), 'Beta');
    await tester.pump();
    await tester.enterText(
        tagField(), c.entries.single.list.nodes.single.tag);
    await tester.pump();
    await back(tester);
    expect(dialog(), findsNothing);
    expect(host.closed, isTrue);
  });

  testWidgets('Keep — экран остаётся, правка на месте', (tester) async {
    final (_, host) = await open(tester);
    await tester.enterText(tagField(), 'Beta');
    await tester.pump();
    await back(tester);
    await choose(tester, 'Keep');
    await tester.pumpAndSettle();
    expect(dialog(), findsNothing);
    expect(host.closed, isFalse);
    expect(find.byType(NodeSettingsScreen), findsOneWidget);
    expect(tester.widget<TextField>(tagField()).controller!.text, 'Beta');
  });

  testWidgets('Save — записано и закрыто', (tester) async {
    final (c, host) = await open(tester);
    await tester.enterText(tagField(), 'Beta');
    await tester.pump();
    await back(tester);
    await choose(tester, 'Save');
    await settle(tester, () => host.closed);
    expect(host.closed, isTrue);
    expect(c.entries.single.list.nodes.single.tag, 'Beta');
  });

  testWidgets('правка Source → Back → диалог; пустой Source при Save — экран '
      'остаётся', (tester) async {
    final (_, host) = await open(tester);
    await tester.tap(find.text('Source'));
    await tester.pumpAndSettle();
    final editor = find.descendant(
        of: find.byKey(const ValueKey('node-source-editor')),
        matching: find.byType(EditableText));
    await tester.enterText(editor, '');
    await tester.pump();
    await back(tester);
    expect(dialog(), findsOneWidget);
    await choose(tester, 'Save');
    await tester.pumpAndSettle();
    expect(host.closed, isFalse);
    expect(find.byType(NodeSettingsScreen), findsOneWidget);
    expect(
        tester
            .widget<LxTextCodeField>(
                find.byKey(const ValueKey('node-source-editor')))
            .controller
            .text,
        '');
  });
}
