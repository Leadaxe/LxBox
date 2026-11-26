import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/home/widgets/errors_counter_row.dart';
import 'package:lxbox/services/app_log.dart';

// §754 — строка «Errors (N)» последняя в Column главного; при edge-to-edge
// она обязана стоять выше полосы системной панели навигации.
void main() {
  setUp(() => AppLog.I.resetForTesting());
  tearDown(() => AppLog.I.resetForTesting());

  testWidgets('errors row stays above the navigation bar inset', (
    tester,
  ) async {
    const navBar = 48.0;
    const height = 600.0;
    tester.view.physicalSize = const Size(400, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    AppLog.I.error('boom');
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(400, height),
            padding: EdgeInsets.only(bottom: navBar),
            viewPadding: EdgeInsets.only(bottom: navBar),
          ),
          child: Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Expanded(child: SizedBox()),
                ErrorsCounterRow(onOpen: () => opened++),
              ],
            ),
          ),
        ),
      ),
    );

    final text = find.byIcon(Icons.error_outline);
    expect(text, findsOneWidget);
    expect(tester.getRect(text).bottom, lessThanOrEqualTo(height - navBar));

    await tester.tap(text);
    expect(opened, 1);
    // Троттлинг уведомлений AppLog держит таймер — дать ему отработать.
    await tester.pump(const Duration(seconds: 2));
  });
}
