// §744 / issue #222 — пульт TV в группе переключателей: стрелки двигают
// только фокус и выходят из группы на краях, выбор — OK/Enter и тап;
// при смене вкладки фокус не остаётся на скрытой странице.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/dpad_radio_group.dart';
import 'package:lxbox/widgets/focus_safe_tab_bar_view.dart';

void main() {
  group('DpadRadioGroup', () {
    late String value;
    final top = FocusNode(debugLabel: 'top');
    final bottom = FocusNode(debugLabel: 'bottom');
    final radios = [
      for (final v in ['a', 'b', 'c']) FocusNode(debugLabel: v),
    ];

    Future<void> pump(WidgetTester tester) async {
      value = 'a';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  TextButton(
                    focusNode: top,
                    onPressed: () {},
                    child: const Text('top'),
                  ),
                  DpadRadioGroup<String>(
                    groupValue: value,
                    onChanged: (v) => setState(() => value = v!),
                    child: Column(
                      children: [
                        for (final (i, v) in ['a', 'b', 'c'].indexed)
                          RadioListTile<String>(
                            focusNode: radios[i],
                            value: v,
                            title: Text('radio $v'),
                          ),
                      ],
                    ),
                  ),
                  TextButton(
                    focusNode: bottom,
                    onPressed: () {},
                    child: const Text('bottom'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('стрелка вниз двигает фокус, но не меняет значение', (
      tester,
    ) async {
      await pump(tester);
      radios[0].requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(radios[1].hasPrimaryFocus, isTrue);
      expect(value, 'a');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(radios[2].hasPrimaryFocus, isTrue);
      expect(value, 'a');
    });

    testWidgets('с последнего пункта вниз — к элементу после группы', (
      tester,
    ) async {
      await pump(tester);
      radios[2].requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(bottom.hasPrimaryFocus, isTrue);
      expect(value, 'a');
    });

    testWidgets('с первого пункта вверх — к элементу перед группой', (
      tester,
    ) async {
      await pump(tester);
      radios[0].requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(top.hasPrimaryFocus, isTrue);
      expect(value, 'a');
    });

    testWidgets('сверху вниз пульт проходит группу насквозь', (tester) async {
      await pump(tester);
      top.requestFocus();
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      expect(bottom.hasPrimaryFocus, isTrue);
      expect(value, 'a');
    });

    for (final key in [
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.space,
    ]) {
      testWidgets('${key.keyLabel} выбирает пункт под фокусом', (tester) async {
        await pump(tester);
        radios[2].requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(key);
        await tester.pump();
        expect(value, 'c');
      });
    }

    testWidgets('тап выбирает', (tester) async {
      await pump(tester);
      await tester.tap(find.text('radio b'));
      await tester.pump();
      expect(value, 'b');
    });

    testWidgets('семантика радиогруппы сохраняется', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      expect(
        tester.getSemantics(find.text('radio a')),
        isSemantics(
          label: 'radio a',
          isInMutuallyExclusiveGroup: true,
          isChecked: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });
  });

  testWidgets('FocusSafeTabBarView: смена вкладки снимает фокус со скрытой', (
    tester,
  ) async {
    // Как с пульта: подсветка фокуса включена — именно она держит
    // страницу живой (keep-alive у InkWell) после ухода с вкладки.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    final hidden = FocusNode(debugLabel: 'hidden');
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'one'),
                  Tab(text: 'two'),
                ],
              ),
            ),
            body: FocusSafeTabBarView(
              children: [
                Center(
                  child: TextButton(
                    focusNode: hidden,
                    onPressed: () => presses++,
                    child: const Text('on page one'),
                  ),
                ),
                const Center(child: Text('page two')),
              ],
            ),
          ),
        ),
      ),
    );
    hidden.requestFocus();
    await tester.pump();
    expect(hidden.hasPrimaryFocus, isTrue);

    await tester.tap(find.text('two'));
    await tester.pumpAndSettle();
    expect(hidden.hasFocus, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(presses, 0);
    expect(hidden.hasFocus, isFalse);
  });
}
