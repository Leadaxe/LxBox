import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';

/// §614/§624 — поиск в LxCodeEditor (панель — Flutter-виджет, сам поиск —
/// в нативе) и синхронизация LxTextCodeField с `TextEditingController` на
/// заглушке (`flutter test` не Android — нативного view нет). Свёртка
/// снята §624.
void main() {
  const json = '{\n  "a": {\n    "b": 1\n  },\n  "c": [1, 2]\n}';

  Future<void> pump(WidgetTester tester, {bool showLineNumbers = false}) async {
    final controller = TextEditingController(text: json);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: LxCodeEditor(
              controller: controller,
              showLineNumbers: showLineNumbers,
              language: LxCodeLanguage.json,
            ),
          ),
        ),
      ),
    );
  }

  const findIcon = ValueKey('lx-code-editor-find');
  const findPanel = ValueKey('lx-code-editor-find-panel');
  const findClose = ValueKey('lx-code-editor-find-close');

  testWidgets('без номеров строк — без поиска', (tester) async {
    await pump(tester);
    expect(find.byKey(findIcon), findsNothing);
  });

  testWidgets('с номерами строк — иконка открывает панель, крестик закрывает',
      (tester) async {
    await pump(tester, showLineNumbers: true);
    expect(find.byKey(findIcon), findsOneWidget);

    await tester.tap(find.byKey(findIcon));
    await tester.pump();
    expect(find.byKey(findPanel), findsOneWidget);
    expect(find.byKey(findIcon), findsNothing);
    expect(find.text('0/0'), findsOneWidget);

    await tester.tap(find.byKey(findClose));
    await tester.pump();
    expect(find.byKey(findPanel), findsNothing);
    expect(find.byKey(findIcon), findsOneWidget);
  });

  testWidgets('LxTextCodeField: синхронизация с TextEditingController', (
    tester,
  ) async {
    final text = TextEditingController(text: '{"a": 1}');
    addTearDown(text.dispose);
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: LxTextCodeField(
              controller: text,
              minLines: 6,
              onChanged: changes.add,
            ),
          ),
        ),
      ),
    );
    final field = find.descendant(
      of: find.byType(LxCodeEditor),
      matching: find.byType(EditableText),
    );
    String shown() => tester.widget<EditableText>(field).controller.text;
    expect(shown(), '{"a": 1}');

    // Запись из кода в TextEditingController → поле, без onChanged.
    text.text = '{"b": 2}';
    await tester.pump();
    expect(shown(), '{"b": 2}');
    expect(changes, isEmpty);

    // Правка в поле → TextEditingController и onChanged.
    await tester.enterText(field, '{"c": 3}');
    await tester.pump();
    expect(text.text, '{"c": 3}');
    expect(changes, ['{"c": 3}']);
  });
}
