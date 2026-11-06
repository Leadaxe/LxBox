// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/subscription_detail_screen.dart';
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

// §626 — подписка: переименование в AppBar (Back с изменённым именем) и
// редактор правила вкладки Filters (Back с правкой) спрашивают общий диалог
// Unsaved changes.

VlessSpec _node(String label) => VlessSpec(
      id: label,
      tag: label,
      label: label,
      server: 'example.com',
      port: 443,
      rawSource: '',
      uuid: '00000000-0000-0000-0000-000000000000',
    );

void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('sub_unsaved_');
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

  Finder unsaved() => find.text('Unsaved changes');

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
        of: find.ancestor(of: unsaved(), matching: find.byType(AlertDialog)),
        matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  Future<SubscriptionEntry> open(
      WidgetTester tester, void Function() onClosed) async {
    final entry = SubscriptionEntry(
      list: SubscriptionServers(
        id: 'sub-1',
        name: 'Sub',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        nodes: [_node('A')],
      ),
    );
    final c = SubscriptionController()..debugSetEntries([entry]);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) =>
                    SubscriptionDetailScreen(entry: entry, controller: c),
              ));
              onClosed();
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return entry;
  }

  group('переименование', () {
    Future<void> startRename(WidgetTester tester, String name) async {
      await tester.tap(find.byTooltip('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.descendant(
              of: find.byType(AppBar), matching: find.byType(TextField)),
          name);
      await tester.pump();
    }

    testWidgets('имя не менялось — Back без диалога', (tester) async {
      var closed = false;
      await open(tester, () => closed = true);
      await startRename(tester, 'Sub');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(unsaved(), findsNothing);
      expect(closed, isTrue);
    });

    testWidgets('новое имя → Back → Discard: закрыт, имя прежнее',
        (tester) async {
      var closed = false;
      final entry = await open(tester, () => closed = true);
      await startRename(tester, 'Other');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(unsaved(), findsOneWidget);
      await choose(tester, 'Discard');
      expect(closed, isTrue);
      expect(entry.name, 'Sub');
    });

    testWidgets('новое имя → Back → Keep: экран остаётся', (tester) async {
      var closed = false;
      await open(tester, () => closed = true);
      await startRename(tester, 'Other');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await choose(tester, 'Keep');
      expect(closed, isFalse);
      expect(find.byType(SubscriptionDetailScreen), findsOneWidget);
    });

    testWidgets('новое имя → Back → Save: переименовано и закрыто',
        (tester) async {
      var closed = false;
      final entry = await open(tester, () => closed = true);
      await startRename(tester, 'Other');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await choose(tester, 'Save');
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(entry.name, 'Other');
    });
  });

  group('редактор правила Filters', () {
    Future<void> openRuleEditor(WidgetTester tester) async {
      await tester.tap(find.text('Filters'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add rule'));
      await tester.pumpAndSettle();
      expect(find.text('Add rule'), findsWidgets);
    }

    bool editorOpen() => find.text('Matches').evaluate().isNotEmpty;

    List<Object?> rules(SubscriptionEntry e) =>
        (e.list as SubscriptionServers).importRules;

    testWidgets('без правок — Back без диалога', (tester) async {
      await open(tester, () {});
      await openRuleEditor(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(unsaved(), findsNothing);
      expect(editorOpen(), isFalse);
    });

    testWidgets('правка → крестик → диалог; Discard без правила',
        (tester) async {
      final entry = await open(tester, () {});
      await openRuleEditor(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Value'), 'ru');
      await tester.pump();
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(unsaved(), findsOneWidget);
      await choose(tester, 'Discard');
      expect(editorOpen(), isFalse);
      expect(rules(entry), isEmpty);
    });

    testWidgets('Keep — редактор остаётся, правка на месте', (tester) async {
      await open(tester, () {});
      await openRuleEditor(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Value'), 'ru');
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await choose(tester, 'Keep');
      expect(editorOpen(), isTrue);
      expect(find.widgetWithText(TextField, 'ru'), findsOneWidget);
    });

    testWidgets('Save — правило добавлено, редактор закрыт', (tester) async {
      final entry = await open(tester, () {});
      await openRuleEditor(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Value'), 'ru');
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await choose(tester, 'Save');
      expect(editorOpen(), isFalse);
      expect(rules(entry), hasLength(1));
    });

    testWidgets('Save при блокировке — редактор остаётся', (tester) async {
      final entry = await open(tester, () {});
      await openRuleEditor(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Path'), 'name');
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await choose(tester, 'Save');
      expect(editorOpen(), isTrue);
      expect(rules(entry), isEmpty);
    });
  });
}
