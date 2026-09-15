import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/screens/direction_edit_screen.dart';

// §442 — редактор Направления: interval больше idle_timeout сохранить можно,
// сборка поднимет idle_timeout до interval. Форма показывает подсказку ровно
// тогда, когда санитайзер вмешается. Проверяется показ, не текст (AGENTS.md).

const _hint = ValueKey('direction-auto-idle-raise-hint');

Future<void> _pump(WidgetTester tester, DirectionAuto auto) async {
  // Секция автовыбора — внизу ListView; высокий экран строит её целиком.
  tester.view.physicalSize = const Size(900, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: DirectionEditScreen(
      initial: Direction(tag: 'vpn-2', label: 'X', auto: auto),
      canDelete: true,
      allNodeTags: const [],
    ),
  ));
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextField, label);

void main() {
  testWidgets('interval больше idle_timeout из хранения → подсказка есть',
      (tester) async {
    await _pump(tester, const DirectionAuto(interval: '2h', idleTimeout: '30m'));
    expect(find.byKey(_hint), findsOneWidget);
  });

  testWidgets('сходящаяся пара → подсказки нет', (tester) async {
    await _pump(tester, const DirectionAuto());
    expect(find.byKey(_hint), findsNothing);
  });

  testWidgets('подсказка следует за вводом, суффикс d распознаётся',
      (tester) async {
    await _pump(tester, const DirectionAuto());

    await tester.enterText(_field('Interval'), '1d');
    await tester.pump();
    expect(find.byKey(_hint), findsOneWidget);

    await tester.enterText(_field('Idle timeout'), '48h');
    await tester.pump();
    expect(find.byKey(_hint), findsNothing);
  });

  testWidgets('нераспознанный interval → подсказки нет', (tester) async {
    await _pump(tester, const DirectionAuto(interval: 'fast', idleTimeout: '1m'));
    expect(find.byKey(_hint), findsNothing);
  });
}
