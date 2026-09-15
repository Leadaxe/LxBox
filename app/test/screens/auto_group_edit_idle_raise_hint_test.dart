import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/screens/auto_group_edit_screen.dart';

// §442 — редактор узла автовыбора: та же подсказка, что у Направления.
// interval больше idle_timeout сохранить можно, сборка поднимет idle_timeout
// до interval. Пустое поле — умолчание AutoSelectParams (15m / 30m).
// Проверяется показ, не текст (AGENTS.md).

const _hint = ValueKey('auto-group-idle-raise-hint');

Future<void> _pump(WidgetTester tester, AutoSelectParams params) async {
  // Поля interval / idle timeout — в свёрнутом Advanced внизу ListView;
  // высокий экран строит его целиком после раскрытия.
  tester.view.physicalSize = const Size(900, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: AutoGroupEditScreen(
      initial: AutoSelectSpec(
          id: 'g1', tag: 'auto', label: 'Auto', params: params),
      candidates: const [],
      canDelete: true,
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Advanced'));
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextField, label);

void main() {
  testWidgets('interval больше idle_timeout из хранения → подсказка есть',
      (tester) async {
    await _pump(
        tester, const AutoSelectParams(interval: '2h', idleTimeout: '30m'));
    expect(find.byKey(_hint), findsOneWidget);
  });

  testWidgets('сходящаяся пара → подсказки нет', (tester) async {
    await _pump(tester, const AutoSelectParams());
    expect(find.byKey(_hint), findsNothing);
  });

  testWidgets('подсказка следует за вводом, суффикс d распознаётся',
      (tester) async {
    await _pump(tester, const AutoSelectParams());

    await tester.enterText(_field('Interval'), '1d');
    await tester.pump();
    expect(find.byKey(_hint), findsOneWidget);

    await tester.enterText(_field('Idle timeout'), '48h');
    await tester.pump();
    expect(find.byKey(_hint), findsNothing);
  });

  testWidgets('пустое поле → умолчание формы', (tester) async {
    await _pump(tester, const AutoSelectParams());

    // Пустой interval = 15m против 10m.
    await tester.enterText(_field('Interval'), '');
    await tester.enterText(_field('Idle timeout'), '10m');
    await tester.pump();
    expect(find.byKey(_hint), findsOneWidget);

    // Пустой idle timeout = 30m против 1h.
    await tester.enterText(_field('Interval'), '1h');
    await tester.enterText(_field('Idle timeout'), '');
    await tester.pump();
    expect(find.byKey(_hint), findsOneWidget);

    // Оба пустые = 15m / 30m.
    await tester.enterText(_field('Interval'), '');
    await tester.pump();
    expect(find.byKey(_hint), findsNothing);
  });

  testWidgets('нераспознанный interval → подсказки нет', (tester) async {
    await _pump(
        tester, const AutoSelectParams(interval: 'fast', idleTimeout: '1m'));
    expect(find.byKey(_hint), findsNothing);
  });
}
