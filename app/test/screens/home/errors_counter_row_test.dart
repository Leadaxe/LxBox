import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/debug_entry.dart';
import 'package:lxbox/screens/home/widgets/errors_counter_row.dart';
import 'package:lxbox/services/app_log.dart';

/// §614 — строка «Errors (N)» на главном: считает error-записи AppLog
/// с последнего открытия журнала, тап открывает журнал и обнуляет счёт.
void main() {
  setUp(() => AppLog.I.markErrorsSeen());

  // Троттлинг AppLog (16 мс) ставит таймер; два окна — до его снятия,
  // иначе таймер переживёт тест и заглушит уведомления следующего.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
  }

  Future<void> pumpRow(WidgetTester tester, VoidCallback onOpen) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(children: [ErrorsCounterRow(onOpen: onOpen)]),
          ),
        ),
      );

  testWidgets('нет ошибок — строки нет', (tester) async {
    await pumpRow(tester, () {});
    AppLog.I.warning('just a warning');
    AppLog.I.info('info');
    await settle(tester);
    expect(find.byKey(ErrorsCounterRow.rowKey), findsNothing);
  });

  testWidgets('считает ошибки обоих источников, тап обнуляет', (tester) async {
    var opened = 0;
    await pumpRow(tester, () => opened++);
    AppLog.I.error('app failure');
    AppLog.I.log(DebugLevel.error, 'core failure', source: DebugSource.core);
    AppLog.I.warning('not counted');
    await settle(tester);

    expect(find.byKey(ErrorsCounterRow.rowKey), findsOneWidget);
    expect(AppLog.I.errorsSinceSeen, 2);
    expect(find.textContaining('2'), findsOneWidget);

    await tester.tap(find.byKey(ErrorsCounterRow.rowKey));
    await settle(tester);

    expect(opened, 1);
    expect(AppLog.I.errorsSinceSeen, 0);
    expect(find.byKey(ErrorsCounterRow.rowKey), findsNothing);
  });
}
