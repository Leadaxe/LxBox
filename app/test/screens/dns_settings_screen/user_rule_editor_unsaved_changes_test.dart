import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/screens/dns_settings_screen/user_rule_editor_sheet.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';

// §626 — шторка DNS-правила: с правкой Back, тап по фону и смахивание вниз
// спрашивают общий диалог Unsaved changes; без правок шторка закрывается.
// Протяжка ведёт шторку за пальцем, как штатная; с правкой шторка ниже
// середины возвращается на место и показывает диалог.

void main() {
  late List<DnsRuleInline> saved;

  Future<void> open(WidgetTester tester) async {
    saved = [];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: TextButton(
              onPressed: () => showUserRuleEditor(
                context,
                isNew: false,
                existing: const DnsRuleInline(
                  name: 'ru',
                  rule: {'rule_set': 'geoip-ru', 'server': 'yandex_doh'},
                ),
                onSave: saved.add,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Edit DNS Rule'), findsOneWidget);
  }

  Finder nameField() => find.widgetWithText(TextField, 'Name');
  Finder dialog() => find.byType(AlertDialog);
  bool sheetOpen() => find.text('Edit DNS Rule').evaluate().isNotEmpty;

  Future<void> edit(WidgetTester tester) async {
    await tester.enterText(nameField(), 'ru2');
    await tester.pump();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  Future<void> swipe(WidgetTester tester) async {
    await tester.fling(find.text('Edit DNS Rule'), const Offset(0, 300), 1500);
    await tester.pumpAndSettle();
  }

  Rect sheetRect(WidgetTester tester) =>
      tester.getRect(find.byType(BottomSheet));

  /// Медленная протяжка вниз на [part] высоты шторки (без рывка).
  Future<void> slowDrag(WidgetTester tester, double part) async {
    final dy = sheetRect(tester).height * part;
    final g = await tester.startGesture(tester.getCenter(find.text('Edit DNS Rule')));
    for (var i = 0; i < 20; i++) {
      await g.moveBy(Offset(0, dy / 20));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  Future<void> tapBarrier(WidgetTester tester) async {
    await tester.tapAt(const Offset(10, 300));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester
        .tap(find.descendant(of: dialog(), matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  testWidgets('без правок — Back, фон, смахивание закрывают без диалога',
      (tester) async {
    for (final exit in [back, tapBarrier, swipe]) {
      await open(tester);
      await exit(tester);
      expect(dialog(), findsNothing);
      expect(sheetOpen(), isFalse);
    }
    expect(saved, isEmpty);
  });

  testWidgets('с правкой — Back, фон и смахивание спрашивают диалог',
      (tester) async {
    for (final exit in [back, tapBarrier, swipe]) {
      await open(tester);
      await edit(tester);
      await exit(tester);
      expect(dialog(), findsOneWidget);
      await choose(tester, 'Discard');
      expect(sheetOpen(), isFalse);
    }
    expect(saved, isEmpty);
  });

  testWidgets('протяжка — шторка едет за пальцем', (tester) async {
    await open(tester);
    final top = sheetRect(tester).top;
    final g = await tester.startGesture(tester.getCenter(find.text('Edit DNS Rule')));
    await g.moveBy(const Offset(0, 20));
    await g.moveBy(const Offset(0, 80));
    await tester.pump();
    expect(sheetRect(tester).top, closeTo(top + 100, 2));
    await g.up();
    await tester.pumpAndSettle();
    expect(sheetRect(tester).top, closeTo(top, 0.5));
  });

  testWidgets('без правок — протяжка ниже середины закрывает, выше — возвращает',
      (tester) async {
    await open(tester);
    await slowDrag(tester, 0.3);
    expect(sheetOpen(), isTrue);
    await slowDrag(tester, 0.7);
    expect(dialog(), findsNothing);
    expect(sheetOpen(), isFalse);
  });

  testWidgets('с правкой — протяжка ниже середины: шторка на месте и диалог',
      (tester) async {
    await open(tester);
    final top = sheetRect(tester).top;
    await edit(tester);
    await slowDrag(tester, 0.3);
    expect(dialog(), findsNothing);
    await slowDrag(tester, 0.7);
    expect(dialog(), findsOneWidget);
    expect(sheetRect(tester).top, closeTo(top, 0.5));
    await choose(tester, 'Keep');
    expect(sheetOpen(), isTrue);
    await slowDrag(tester, 0.7);
    await choose(tester, 'Save');
    expect(sheetOpen(), isFalse);
    expect(saved.single.name, 'ru2');
  });

  testWidgets('Keep — шторка остаётся, правка на месте', (tester) async {
    await open(tester);
    await edit(tester);
    await swipe(tester);
    await choose(tester, 'Keep');
    expect(dialog(), findsNothing);
    expect(sheetOpen(), isTrue);
    expect(tester.widget<TextField>(nameField()).controller!.text, 'ru2');
  });

  testWidgets('Save — правило отдано и шторка закрыта', (tester) async {
    await open(tester);
    await edit(tester);
    await back(tester);
    await choose(tester, 'Save');
    expect(sheetOpen(), isFalse);
    expect(saved.single.name, 'ru2');
  });

  testWidgets('Save с битым JSON — шторка остаётся', (tester) async {
    await open(tester);
    await tester.enterText(
        find.descendant(
            of: find.byType(LxTextCodeField),
            matching: find.byType(EditableText)),
        '{"server":');
    await tester.pump();
    await back(tester);
    await choose(tester, 'Save');
    expect(sheetOpen(), isTrue);
    expect(saved, isEmpty);
  });
}
