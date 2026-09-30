import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';
import 'package:re_editor/re_editor.dart';

/// §591 019-CONFIG_EDITOR, строка 366 — «Read-only меню показывает
/// Cut/Paste — не проверено, блокируются ли».
///
/// [LxSelectionToolbarController.show] (`lx_code_editor.dart:264-277`) кладёт
/// в меню `Cut`/`Paste` безусловно — `readOnly` туда не приходит вообще
/// (виджет передаёт его только в `CodeEditor.readOnly`, а не в контроллер
/// меню). А `CodeLineEditingController.cut()`/`.paste()`
/// (`re_editor: _code_line.dart:2217,2432`) — тоже безусловные: `readOnly`
/// в пакете держит только клавиатурный путь ввода
/// (`_code_input.dart:327,424`, `_code_shortcuts.dart:84,284`), а не
/// программные вызовы контроллера. Значит тап по пункту меню режет/вставляет
/// текст даже в read-only редакторе — ровно то, о чём строка предупреждает.
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

  testWidgets(
      'read-only: меню всё ещё показывает Cut/Paste (не скрыты)',
      (tester) async {
    final controller = await pumpReadOnlyEditor(tester);
    await longPressWord(tester);

    // Документирует текущее поведение: пункты есть, хотя блокировки нет.
    expect(item('Cut'), findsOneWidget,
        reason: 'если это когда-нибудь станет findsNothing — значит, '
            'меню научили прятать Cut/Paste в read-only, обнови тест');
    expect(item('Paste'), findsOneWidget);
    expect(controller.selectedText, 'alpha');
  });

  testWidgets('read-only: тап Cut всё равно вырезает текст (расхождение)',
      (tester) async {
    final controller = await pumpReadOnlyEditor(tester);
    await longPressWord(tester);

    await tester.tap(item('Cut'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(copied, ['alpha'], reason: 'cut не скопировал выделенное');
    expect(controller.text, startsWith(' bravo charlie'),
        reason: 'read-only редактор не должен терять текст по Cut из меню, '
            'но LxSelectionToolbarController не знает о readOnly — правит '
            'текст как обычно (§591/366)');
  });

  testWidgets('read-only: тап Paste всё равно подменяет выделение (расхождение)',
      (tester) async {
    final controller = await pumpReadOnlyEditor(tester);
    await longPressWord(tester);
    expect(controller.selectedText, 'alpha');

    await tester.tap(item('Paste'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(controller.text, startsWith('PASTED bravo charlie'),
        reason: 'read-only редактор не должен принимать вставку из меню, '
            'но паста прошла — LxSelectionToolbarController не проверяет '
            'readOnly (§591/366)');
  });
}
