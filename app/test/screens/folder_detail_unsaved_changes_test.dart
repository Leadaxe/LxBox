// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/folder_detail_screen.dart';
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

// §626 — папка: диалог Edit server (Back и тап по фону с правкой) и
// переименование в AppBar (Back с изменённым именем) спрашивают общий
// диалог Unsaved changes.
void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('folder_unsaved_');
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
  const next = 'vless://u2@h2.example:443?type=ws&security=tls#Beta';

  Finder unsaved() => find.text('Unsaved changes');

  Future<SubscriptionController> openFolder(
      WidgetTester tester, void Function() onClosed) async {
    final c = SubscriptionController();
    await tester.runAsync(() async {
      await c.init();
      await c.addFolder('F');
      await c.addMembersToFolder(0, link);
    });
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) =>
                    FolderDetailScreen(entry: c.entries.single, controller: c),
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
    return c;
  }

  String memberRaw(SubscriptionController c) =>
      (c.entries.single.list as FolderServers).members.single.raw;

  Future<void> openEditServer(WidgetTester tester) async {
    await tester.longPress(find.text('Alpha').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit…'));
    await tester.pumpAndSettle();
    expect(find.text('Edit server'), findsOneWidget);
  }

  LxCodeEditor editor(WidgetTester tester) =>
      tester.widget<LxCodeEditor>(find.byType(LxCodeEditor));

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
        of: find.ancestor(of: unsaved(), matching: find.byType(AlertDialog)),
        matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  group('Edit server', () {
    testWidgets('без правок — Back закрывает без диалога', (tester) async {
      await openFolder(tester, () {});
      await openEditServer(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(unsaved(), findsNothing);
      expect(find.text('Edit server'), findsNothing);
    });

    testWidgets('правка → тап по фону → диалог; Keep — правка на месте',
        (tester) async {
      await openFolder(tester, () {});
      await openEditServer(tester);
      editor(tester).controller.text = next;
      await tester.pump();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(unsaved(), findsOneWidget);
      await choose(tester, 'Keep');
      expect(unsaved(), findsNothing);
      expect(find.text('Edit server'), findsOneWidget);
      expect(editor(tester).controller.text, next);
    });

    testWidgets('правка → Back → Discard: закрыт, тело прежнее',
        (tester) async {
      final c = await openFolder(tester, () {});
      await openEditServer(tester);
      editor(tester).controller.text = next;
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(unsaved(), findsOneWidget);
      await choose(tester, 'Discard');
      expect(find.text('Edit server'), findsNothing);
      expect(memberRaw(c), link);
    });

    testWidgets('правка → Back → Save: записано тем же путём, что Save',
        (tester) async {
      final c = await openFolder(tester, () {});
      await openEditServer(tester);
      editor(tester).controller.text = next;
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await choose(tester, 'Save');
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(find.text('Edit server'), findsNothing);
      expect(memberRaw(c), next);
    });
  });

  group('переименование папки', () {
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
      await openFolder(tester, () => closed = true);
      await startRename(tester, 'F');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(unsaved(), findsNothing);
      expect(closed, isTrue);
    });

    testWidgets('новое имя → Back → Discard: закрыт, имя прежнее',
        (tester) async {
      var closed = false;
      final c = await openFolder(tester, () => closed = true);
      await startRename(tester, 'G');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(unsaved(), findsOneWidget);
      await choose(tester, 'Discard');
      expect(closed, isTrue);
      expect(c.entries.single.name, 'F');
    });

    testWidgets('новое имя → Back → Keep: экран и поле остаются',
        (tester) async {
      var closed = false;
      await openFolder(tester, () => closed = true);
      await startRename(tester, 'G');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await choose(tester, 'Keep');
      expect(closed, isFalse);
      expect(find.byType(FolderDetailScreen), findsOneWidget);
    });

    testWidgets('новое имя → Back → Save: переименовано и закрыто',
        (tester) async {
      var closed = false;
      final c = await openFolder(tester, () => closed = true);
      await startRename(tester, 'G');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await choose(tester, 'Save');
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(c.entries.single.name, 'G');
    });
  });
}
