import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/source_replace.dart';
import 'package:lxbox/screens/source_replace_screen.dart';

// §626 — редактор свёртки: Back с несохранённой правкой спрашивает общий
// диалог Unsaved changes.

class _Host {
  bool closed = false;
  SourceReplaceResult? result;
}

void main() {
  const initial = SourceReplace(mode: ReplaceMode.manual, tag: 'vpn-1');

  Future<_Host> open(WidgetTester tester) async {
    final host = _Host();
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              host.result = await openSourceReplaceEditor(context,
                  initial: initial, defaultTag: 'sub');
              host.closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return host;
  }

  Finder nameField() => find.byType(TextField).first;
  Finder dialog() => find.byType(AlertDialog);

  Future<void> edit(WidgetTester tester, String text) async {
    await tester.enterText(nameField(), text);
    await tester.pump();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.pageBack();
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester
        .tap(find.descendant(of: dialog(), matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  testWidgets('без правок — выход без диалога', (tester) async {
    final host = await open(tester);
    await back(tester);
    expect(dialog(), findsNothing);
    expect(host.closed, isTrue);
    expect(host.result, isNull);
  });

  testWidgets('вернул как было — диалога нет', (tester) async {
    final host = await open(tester);
    await edit(tester, 'free');
    await edit(tester, 'vpn-1');
    await back(tester);
    expect(dialog(), findsNothing);
    expect(host.closed, isTrue);
  });

  testWidgets('правка → Back → диалог; Discard закрывает без результата',
      (tester) async {
    final host = await open(tester);
    await edit(tester, 'free');
    await back(tester);
    expect(dialog(), findsOneWidget);
    await choose(tester, 'Discard');
    expect(host.closed, isTrue);
    expect(host.result, isNull);
  });

  testWidgets('Keep — экран остаётся, правка на месте', (tester) async {
    final host = await open(tester);
    await edit(tester, 'free');
    await back(tester);
    await choose(tester, 'Keep');
    expect(dialog(), findsNothing);
    expect(host.closed, isFalse);
    expect(tester.widget<TextField>(nameField()).controller!.text, 'free');
  });

  testWidgets('Save — результат как у кнопки Save, экран закрыт',
      (tester) async {
    final host = await open(tester);
    await edit(tester, 'free');
    await back(tester);
    await choose(tester, 'Save');
    expect(host.closed, isTrue);
    expect(host.result?.replace?.tag, 'free');
  });
}
