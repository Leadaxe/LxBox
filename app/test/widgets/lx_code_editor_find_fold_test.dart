import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';
import 'package:re_editor/re_editor.dart';

/// §614 — свёртка и поиск в LxCodeEditor: включены по умолчанию там, где
/// есть номера строк; иконка поиска открывает панель, крестик закрывает.
void main() {
  const json = '{\n  "a": {\n    "b": 1\n  },\n  "c": [1, 2]\n}';

  Future<CodeLineEditingController> pump(
    WidgetTester tester, {
    bool showLineNumbers = false,
  }) async {
    final controller = CodeLineEditingController.fromText(json);
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
    // Старт мигания каретки — таймер 100 мс; без паузы он переживёт тест.
    await tester.pump(const Duration(milliseconds: 400));
    return controller;
  }

  const findIcon = ValueKey('lx-code-editor-find');
  const findPanel = ValueKey('lx-code-editor-find-panel');
  const findClose = ValueKey('lx-code-editor-find-close');

  testWidgets('без номеров строк — ни поиска, ни свёртки', (tester) async {
    await pump(tester);
    expect(find.byKey(findIcon), findsNothing);
    expect(find.byType(DefaultCodeChunkIndicator), findsNothing);
  });

  testWidgets('с номерами строк — свёртка и поиск', (tester) async {
    await pump(tester, showLineNumbers: true);
    expect(find.byType(DefaultCodeChunkIndicator), findsOneWidget);
    expect(find.byKey(findIcon), findsOneWidget);

    await tester.tap(find.byKey(findIcon));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(findPanel), findsOneWidget);
    expect(find.byKey(findIcon), findsNothing);

    await tester.enterText(
      find.descendant(
        of: find.byKey(findPanel),
        matching: find.byType(TextField),
      ),
      '"b"',
    );
    // Поиск пакет считает в изоляте — нужно реальное время, не фейковое.
    for (var i = 0; i < 50 && find.text('1/1').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('1/1'), findsOneWidget);

    await tester.tap(find.byKey(findClose));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(findPanel), findsNothing);
    expect(find.byKey(findIcon), findsOneWidget);
  });
}
