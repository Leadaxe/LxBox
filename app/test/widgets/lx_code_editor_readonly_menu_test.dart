import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';
import 'package:re_editor/re_editor.dart';

/// §591 019-CONFIG_EDITOR — «Read-only меню показывает Cut/Paste»; §607 —
/// исправлено.
///
/// `CodeLineEditingController.cut()`/`.paste()` (`re_editor:
/// _code_line.dart:2217,2432`) безусловны: `readOnly` в пакете держит только
/// клавиатурный ввод (`_code_input.dart:327,424`, `_code_shortcuts.dart:84,284`).
/// Поэтому [LxSelectionToolbarController] в read-only не кладёт в меню Cut и
/// Paste вовсе — остаются Copy и Select all.
void main() {
  const text = 'alpha bravo charlie\nsecond line here\n';

  late List<String> copied;

  setUp(() {
    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': 'PASTED'};
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<CodeLineEditingController> pumpReadOnlyEditor(
      WidgetTester tester) async {
    final controller = CodeLineEditingController.fromText(text);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: LxCodeEditor(controller: controller, readOnly: true),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    return controller;
  }

  Future<void> longPressWord(WidgetTester tester) async {
    await tester.longPressAt(const Offset(40, 20));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Finder item(String label) => find.widgetWithText(TextButton, label);

  testWidgets('read-only: в меню нет Cut/Paste, есть Copy/Select all',
      (tester) async {
    final controller = await pumpReadOnlyEditor(tester);
    await longPressWord(tester);

    expect(controller.selectedText, 'alpha');
    expect(item('Cut'), findsNothing);
    expect(item('Paste'), findsNothing);
    expect(item('Copy'), findsOneWidget);
    expect(item('Select all'), findsOneWidget);
  });

  testWidgets('read-only: Copy копирует, текст не меняется', (tester) async {
    final controller = await pumpReadOnlyEditor(tester);
    await longPressWord(tester);

    await tester.tap(item('Copy'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(copied, ['alpha']);
    expect(controller.text, text);
  });

  testWidgets('обычный режим: Cut/Paste в меню есть', (tester) async {
    final controller = CodeLineEditingController.fromText(text);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: LxCodeEditor(controller: controller),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await longPressWord(tester);

    expect(item('Cut'), findsOneWidget);
    expect(item('Paste'), findsOneWidget);
  });
}
