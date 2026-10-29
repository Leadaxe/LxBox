// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
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

// §686 — карточка auto-узла папки: Settings — форма группы над текстом
// Source, Source — хранимая запись `kind: auto`, Save пишет её через
// updateAutoMemberAt; битый текст и незнакомые ключи ничего не пишут. JSON
// группы-правила — без кнопки Edit JSON. Проверяется поведение, не текст.
void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('node_auto_');
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

  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  AutoSelectSpec group(SubscriptionController c) =>
      (c.entries.single.list as FolderServers).members.last.node
          as AutoSelectSpec;

  Future<SubscriptionController> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final c = SubscriptionController();
    await tester.runAsync(() async {
      await c.init();
      await c.addFolder('F');
      await c.addMembersToFolder(0,
          'vless://u1@h1.example:443?type=ws&security=tls#Alpha\n'
          'vless://u2@h2.example:443?type=ws&security=tls#Beta');
      await c.addAutoMemberToFolder(
          0, AutoSelectSpec(id: 'g', tag: 'Fast', label: 'Fast'));
    });
    await tester.pumpWidget(MaterialApp(
      home: NodeSettingsScreen(
        entry: c.entries.single,
        index: 0,
        memberIndex: 2,
        subController: c,
      ),
    ));
    await settle(
        tester, () => find.byType(TabBarView).evaluate().isNotEmpty);
    return c;
  }

  Finder form() => find.byKey(const ValueKey('node-auto-group-form'));
  Finder nameField() =>
      find.descendant(of: form(), matching: find.byType(TextField)).first;

  Future<TextEditingController> sourceCtrl(WidgetTester tester) async {
    await tester.tap(find.text('Source'));
    await tester.pumpAndSettle();
    return tester
        .widget<LxTextCodeField>(
            find.byKey(const ValueKey('node-source-editor')))
        .controller;
  }

  Future<void> toSettings(WidgetTester tester) async {
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Save'));
    await settle(tester, () => false);
  }

  testWidgets('Settings — форма группы, без Info/Detour/TLS; Source — запись',
      (tester) async {
    await open(tester);
    expect(form(), findsOneWidget);
    expect(find.text('Protocol'), findsNothing);
    expect(find.text('Detour server'), findsNothing);
    final src = await sourceCtrl(tester);
    final j = jsonDecode(src.text) as Map<String, dynamic>;
    expect(j['kind'], 'auto');
    expect(j['tag'], 'Fast');
  });

  testWidgets('правка формы переписывает Source, Save пишет новое имя',
      (tester) async {
    final c = await open(tester);
    await tester.enterText(nameField(), 'Slow');
    await tester.pump();
    final src = await sourceCtrl(tester);
    expect((jsonDecode(src.text) as Map)['tag'], 'Slow');
    expect(group(c).tag, 'Fast', reason: 'до Save запись прежняя');
    await save(tester);
    expect(group(c).tag, 'Slow');
  });

  testWidgets('правка Source меняет форму; битый Source гасит форму',
      (tester) async {
    await open(tester);
    final src = await sourceCtrl(tester);
    final j = jsonDecode(src.text) as Map<String, dynamic>;
    j['tag'] = 'Other';
    src.text = jsonEncode(j);
    await tester.pump();
    await toSettings(tester);
    expect(tester.widget<TextField>(nameField()).controller!.text, 'Other');
    expect(find.byKey(const ValueKey('auto-group-form-off')), findsNothing,
        reason: 'форма активна');

    src.text = '{"kind": "auto",';
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('auto-group-form-off')), findsOneWidget,
        reason: 'форма неактивна');
    expect(tester.widget<TextField>(nameField()).controller!.text, 'Other',
        reason: 'форма показывает последнее разобранное');
  });

  testWidgets('Save: битый JSON и незнакомый ключ ничего не пишут',
      (tester) async {
    final c = await open(tester);
    final src = await sourceCtrl(tester);
    final good = src.text;

    src.text = '{"kind": "auto", "tag": "Broken"';
    await tester.pump();
    await save(tester);
    expect(group(c).tag, 'Fast');
    expect(src.text, '{"kind": "auto", "tag": "Broken"',
        reason: 'текст в редакторе остаётся');

    final j = jsonDecode(good) as Map<String, dynamic>;
    j['tag'] = 'Unknown';
    j['fold'] = true;
    src.text = jsonEncode(j);
    await tester.pump();
    await save(tester);
    expect(group(c).tag, 'Fast');
  });

  testWidgets('JSON группы-правила: без Edit JSON, состав — строкой',
      (tester) async {
    await open(tester);
    await tester.tap(find.text('JSON'));
    await tester.pumpAndSettle();
    expect(find.text('Edit JSON'), findsNothing);
    final view = tester.widget<LxJsonView>(find.byType(LxJsonView));
    final j = jsonDecode(view.text) as Map<String, dynamic>;
    expect(j['outbounds'], isA<String>());
  });
}
