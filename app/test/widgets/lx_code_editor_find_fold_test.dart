import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/config_parse.dart';
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

  // §624 доработка 2 — кнопки над рамкой, подпись слева, кнопка Format.
  const formatBtn = ValueKey('lx-code-editor-format');
  const bar = ValueKey('lx-code-editor-bar');

  Future<TextEditingController> pumpField(WidgetTester tester, String text,
      {List<String>? changes, bool readOnly = false}) async {
    final c = TextEditingController(text: text);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: LxTextCodeField(
              key: UniqueKey(),
              controller: c,
              minLines: 6,
              readOnly: readOnly,
              onChanged: changes?.add,
              header: const Text('caption'),
            ),
          ),
        ),
      ),
    );
    return c;
  }

  testWidgets('строка кнопок над рамкой: подпись слева, поиск и Format справа',
      (tester) async {
    await pumpField(tester, '{"a":1}');
    Finder inBar(Finder f) => find.descendant(of: find.byKey(bar), matching: f);
    expect(inBar(find.text('caption')), findsOneWidget);
    expect(inBar(find.byKey(findIcon)), findsOneWidget);
    expect(inBar(find.byKey(formatBtn)), findsOneWidget);
    final barBottom = tester.getBottomLeft(find.byKey(bar)).dy;
    final fieldTop = tester.getTopLeft(find.byType(TextField)).dy;
    expect(fieldTop, greaterThanOrEqualTo(barBottom),
        reason: 'кнопки не внутри рамки');
    expect(tester.getTopLeft(find.byKey(formatBtn)).dx,
        greaterThan(tester.getTopLeft(find.text('caption')).dx));

    // Поиск открыт — панель вместо строки кнопок, подпись остаётся.
    await tester.tap(find.byKey(findIcon));
    await tester.pump();
    expect(find.byKey(bar), findsNothing);
    expect(find.byKey(findPanel), findsOneWidget);
    expect(find.text('caption'), findsOneWidget);
  });

  testWidgets('свои actions — в строке над рамкой (Copy LxJsonView)',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LxJsonView(
            text: '{"a": 1}',
            height: 200,
            actions: [Icon(Icons.copy, key: ValueKey('copy'))],
          ),
        ),
      ),
    );
    expect(
        find.descendant(
            of: find.byKey(bar), matching: find.byKey(const ValueKey('copy'))),
        findsOneWidget);
    expect(find.byKey(formatBtn), findsNothing, reason: 'только чтение');
  });

  testWidgets('Format не виден: не JSON или только чтение', (tester) async {
    await pumpField(tester, 'vless://x@h:1#n');
    expect(find.byKey(formatBtn), findsNothing);
    await pumpField(tester, '{"a":1}', readOnly: true);
    expect(find.byKey(formatBtn), findsNothing);
  });

  testWidgets('Format: JSON5 → JSON с отступом 2, в контроллер и onChanged',
      (tester) async {
    final changes = <String>[];
    final c = await pumpField(tester, '{a: 1, b: [1, 2,],}', changes: changes);
    await tester.tap(find.byKey(formatBtn));
    await tester.pumpAndSettle();
    const want = '{\n  "a": 1,\n  "b": [\n    1,\n    2\n  ]\n}';
    expect(c.text, want);
    expect(changes, [want]);
  });

  testWidgets('Format: битый JSON — снек, текст не меняется', (tester) async {
    final changes = <String>[];
    final c = await pumpField(tester, '{"a": 1,, }', changes: changes);
    await tester.tap(find.byKey(formatBtn));
    await tester.pump();
    expect(find.textContaining('Failed to parse JSON: '), findsOneWidget);
    expect(c.text, '{"a": 1,, }');
    expect(changes, isEmpty);
  });

  testWidgets('Format: комментарии — диалог; Cancel не трогает, Format '
      'форматирует', (tester) async {
    const src = '{\n  // note\n  "a": 1\n}';
    final c = await pumpField(tester, src);
    await tester.tap(find.byKey(formatBtn));
    await tester.pumpAndSettle();
    expect(find.text('Comments will be removed'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.text, src);

    await tester.tap(find.byKey(formatBtn));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('lx-code-editor-format-confirm')));
    await tester.pumpAndSettle();
    expect(c.text, '{\n  "a": 1\n}');
  });

  test('hasJson5Comments: только вне строк', () {
    expect(hasJson5Comments('{"u": "http://x/*y"}'), isFalse);
    expect(hasJson5Comments(r"{'a': 'b\\'} // c"), isTrue);
    expect(hasJson5Comments(r'{"a": "\"//"}'), isFalse);
    expect(hasJson5Comments('{/* c */ "a": 1}'), isTrue);
  });
}
