// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_spec.dart';
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

/// Меню члена папки: у авто-узла нет «Move out of folder» (одиночным
/// сервером группа стала бы пустой записью), «Move to folder…» остаётся.
void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('folder_menu_');
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

  testWidgets('long-press: сервер — Move out есть, авто-узел — нет',
      (tester) async {
    final c = SubscriptionController();
    // dart:io вне fake-async зоны testWidgets.
    await tester.runAsync(() async {
      await c.init();
      await c.addFolder('F');
      await c.addMembersToFolder(
          0, 'vless://u1@h1.example:443?type=ws&security=tls#Alpha');
      await c.addAutoMemberToFolder(
          0, AutoSelectSpec(id: 'g', tag: 'Fast', label: 'Fast'));
    });

    await tester.pumpWidget(MaterialApp(
      home: FolderDetailScreen(entry: c.entries.single, controller: c),
    ));
    await tester.pumpAndSettle();

    Future<void> openMenu(String title) async {
      await tester.longPress(find.text(title).first);
      await tester.pumpAndSettle();
      expect(find.text('Move to folder…'), findsOneWidget);
    }

    Future<void> closeMenu() async {
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    }

    await openMenu('Alpha');
    expect(find.text('Move out of folder'), findsOneWidget);
    await closeMenu();

    await openMenu('Fast');
    expect(find.text('Move out of folder'), findsNothing);
    await closeMenu();
  });

  // §615 — «Edit server» члена папки: поле на LxCodeEditor (как §614),
  // подсветка JSON по `{` на лету, сохранение — прежним путём.
  testWidgets('Edit server: редактор с подсветкой, Save пишет новое тело',
      (tester) async {
    final c = SubscriptionController();
    await tester.runAsync(() async {
      await c.init();
      await c.addFolder('F');
      await c.addMembersToFolder(
          0, 'vless://u1@h1.example:443?type=ws&security=tls#Alpha');
    });
    await tester.pumpWidget(MaterialApp(
      home: FolderDetailScreen(entry: c.entries.single, controller: c),
    ));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Alpha').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit…'));
    await tester.pumpAndSettle();

    // §624 — под `flutter test` поле — заглушка на TextField внутри
    // LxCodeEditor; отдельного TextField диалога нет.
    expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        findsOneWidget);
    LxCodeEditor editor() =>
        tester.widget<LxCodeEditor>(find.byType(LxCodeEditor));
    expect(editor().controller.text, contains('vless://u1@h1.example'));
    expect(editor().language, LxCodeLanguage.uri, reason: 'ссылка — URI');

    editor().controller.text = '{"type": "direct"';
    await tester.pump();
    expect(editor().language, LxCodeLanguage.json,
        reason: 'недописанный JSON — подсветка по `{`');

    const next = 'vless://u2@h2.example:443?type=ws&security=tls#Beta';
    editor().controller.text = next;
    await tester.pump();
    expect(editor().language, LxCodeLanguage.uri);
    await tester.tap(find.text('Save'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect((c.entries.single.list as FolderServers).members.single.raw, next);
  });

  /// Подтверждение удаления папки называет авто-узлы; папке из одних
  /// авто-узлов «Keep servers» не предлагается.
  Future<void> openDeleteDialog(WidgetTester tester,
      {required bool withServer}) async {
    final c = SubscriptionController();
    await tester.runAsync(() async {
      await c.init();
      await c.addFolder('F');
      if (withServer) {
        await c.addMembersToFolder(
            0, 'vless://u1@h1.example:443?type=ws&security=tls#Alpha');
      }
      await c.addAutoMemberToFolder(
          0, AutoSelectSpec(id: 'g', tag: 'Fast', label: 'Fast'));
      await c.addAutoMemberToFolder(
          0, AutoSelectSpec(id: 'h', tag: 'Stable', label: 'Stable'));
    });
    await tester.pumpWidget(MaterialApp(
      home: FolderDetailScreen(entry: c.entries.single, controller: c),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete folder'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Auto nodes are deleted with the folder: Fast, Stable'),
        findsOneWidget);
  }

  testWidgets('удаление папки: авто-узлы названы, Keep servers остаётся',
      (tester) async {
    await openDeleteDialog(tester, withServer: true);
    expect(find.text('Keep servers'), findsOneWidget);
  });

  testWidgets('удаление папки из одних авто-узлов: без Keep servers',
      (tester) async {
    await openDeleteDialog(tester, withServer: false);
    expect(find.text('Keep servers'), findsNothing);
    expect(find.text('Delete folder & servers'), findsOneWidget);
  });
}
