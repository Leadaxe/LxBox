// §746 — пульт TV уходит из текстового поля стрелками, когда каретка на
// краю; внутри текста стрелки двигают каретку как раньше.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/dpad_text_field_exit.dart';

void main() {
  late FocusNode top, field, multi, bottom, left, right;
  late TextEditingController ctrl, multiCtrl;

  setUp(() {
    top = FocusNode(debugLabel: 'top');
    field = FocusNode(debugLabel: 'field');
    multi = FocusNode(debugLabel: 'multi');
    bottom = FocusNode(debugLabel: 'bottom');
    left = FocusNode(debugLabel: 'left');
    right = FocusNode(debugLabel: 'right');
    ctrl = TextEditingController(text: 'abc');
    multiCtrl = TextEditingController(text: 'one\ntwo\nthree');
  });

  Future<void> pump(WidgetTester tester, {bool withLayer = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: withLayer
            ? (context, child) => DpadTextFieldExit(child: child!)
            : null,
        home: Scaffold(
          body: Column(
            children: [
              TextButton(
                focusNode: top,
                onPressed: () {},
                child: const Text('top'),
              ),
              Row(
                children: [
                  TextButton(
                    focusNode: left,
                    onPressed: () {},
                    child: const Text('L'),
                  ),
                  Expanded(
                    child: TextField(focusNode: field, controller: ctrl),
                  ),
                  TextButton(
                    focusNode: right,
                    onPressed: () {},
                    child: const Text('R'),
                  ),
                ],
              ),
              TextField(focusNode: multi, controller: multiCtrl, maxLines: 4),
              TextButton(
                focusNode: bottom,
                onPressed: () {},
                child: const Text('bottom'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> focusAt(
    WidgetTester tester,
    FocusNode node,
    TextEditingController c,
    int offset,
  ) async {
    node.requestFocus();
    await tester.pump();
    c.selection = TextSelection.collapsed(offset: offset);
    await tester.pump();
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await tester.pump();
  }

  group('однострочное поле', () {
    // Каждое направление — отдельный тест: обратная стрелка сразу после
    // перехода по истории обхода Flutter возвращает на прежний узел.
    testWidgets('↓ уводит фокус вниз', (tester) async {
      await pump(tester);
      await focusAt(tester, field, ctrl, 1);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(multi.hasPrimaryFocus, isTrue);
      expect(ctrl.text, 'abc');
    });

    testWidgets('↑ уводит фокус вверх', (tester) async {
      await pump(tester);
      await focusAt(tester, field, ctrl, 1);
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(top.hasPrimaryFocus, isTrue);
      expect(ctrl.text, 'abc');
    });

    testWidgets('←/→ внутри текста двигают каретку, фокус в поле', (
      tester,
    ) async {
      await pump(tester);
      await focusAt(tester, field, ctrl, 1);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(field.hasPrimaryFocus, isTrue);
      expect(ctrl.selection.baseOffset, 2);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(field.hasPrimaryFocus, isTrue);
      expect(ctrl.selection.baseOffset, 0);
    });

    testWidgets('← в начале уводит фокус к соседу слева', (tester) async {
      await pump(tester);
      await focusAt(tester, field, ctrl, 0);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(left.hasPrimaryFocus, isTrue);
    });

    testWidgets('→ в конце уводит фокус к соседу справа', (tester) async {
      await pump(tester);
      await focusAt(tester, field, ctrl, 3);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(right.hasPrimaryFocus, isTrue);
    });

    testWidgets('→ с выделением сворачивает его, а не уходит', (tester) async {
      await pump(tester);
      field.requestFocus();
      await tester.pump();
      ctrl.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
      await tester.pump();
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(field.hasPrimaryFocus, isTrue);
      expect(ctrl.selection, const TextSelection.collapsed(offset: 3));
    });

    testWidgets('Shift+← выделяет, как раньше', (tester) async {
      await pump(tester);
      await focusAt(tester, field, ctrl, 2);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(field.hasPrimaryFocus, isTrue);
      expect(ctrl.selection.isCollapsed, isFalse);
    });

    testWidgets('ввод текста не ломается', (tester) async {
      await pump(tester);
      await focusAt(tester, field, ctrl, 3);
      await tester.enterText(find.byType(TextField).first, 'abcd');
      expect(ctrl.text, 'abcd');
      expect(field.hasPrimaryFocus, isTrue);
    });

    testWidgets('без слоя ↓ фокус не уводит (дефект воспроизводится)', (
      tester,
    ) async {
      await pump(tester, withLayer: false);
      await focusAt(tester, field, ctrl, 1);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(field.hasPrimaryFocus, isTrue);
    });
  });

  group('многострочное поле', () {
    testWidgets('↓ в середине — по строкам, с последней — наружу', (
      tester,
    ) async {
      await pump(tester);
      await focusAt(tester, multi, multiCtrl, 1); // строка «one»
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(multi.hasPrimaryFocus, isTrue);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(multi.hasPrimaryFocus, isTrue);
      expect(multiCtrl.selection.baseOffset, greaterThan(8)); // «three»
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(bottom.hasPrimaryFocus, isTrue);
    });

    testWidgets('↑ с первой строки — наружу, из середины — по строкам', (
      tester,
    ) async {
      await pump(tester);
      await focusAt(tester, multi, multiCtrl, 5); // строка «two»
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(multi.hasPrimaryFocus, isTrue);
      expect(multiCtrl.selection.baseOffset, lessThan(4));
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(multi.hasPrimaryFocus, isFalse);
    });
  });

  testWidgets('вне поля стрелки ведут фокус как раньше', (tester) async {
    await pump(tester);
    top.requestFocus();
    await tester.pump();
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(top.hasPrimaryFocus, isFalse);
  });
}
