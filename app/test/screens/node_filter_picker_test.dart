import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/node_filter_picker_screen.dart';

// §702 — пикер фильтра Направления: тап эмодзи пишет его в OR-паттерн и
// меняет счётчик, повторный тап убирает, инверсия переворачивает отметки,
// ✓ возвращает паттерн и инверсию.

const _pool = ['🇩🇪 Berlin', '🇩🇪 Munich', '🇳🇱 Amsterdam', '🇺🇸 NYC'];

void main() {
  testWidgets('emoji toggle, invert and apply', (tester) async {
    NodeFilterPick? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async {
            result = await Navigator.push<NodeFilterPick>(
              ctx,
              MaterialPageRoute(
                builder: (_) => const NodeFilterPickerScreen(
                    pattern: '', invert: false, pool: _pool),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('4 / 4 match'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, '🇩🇪 2'));
    await tester.pump();
    expect(find.widgetWithText(TextField, '🇩🇪'), findsOneWidget);
    expect(find.text('2 / 4 match'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, '🇳🇱 1'));
    await tester.pump();
    expect(find.widgetWithText(TextField, '🇩🇪|🇳🇱'), findsOneWidget);
    expect(find.text('3 / 4 match'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, '🇩🇪 2'));
    await tester.pump();
    expect(find.widgetWithText(TextField, '🇳🇱'), findsOneWidget);
    expect(find.text('1 / 4 match'), findsOneWidget);

    await tester.tap(find.text('!'));
    await tester.pump();
    expect(find.text('3 / 4 match'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();
    expect(result?.pattern, '🇳🇱');
    expect(result?.invert, isTrue);
  });
}
