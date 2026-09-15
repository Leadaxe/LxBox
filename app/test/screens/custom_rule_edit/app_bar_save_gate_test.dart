import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/screens/custom_rule_edit_screen.dart';

// §447 — Save в AppBar редактора правила идёт через ту же проверку, что Save
// формы: массив или невалидный JSON не сохраняются, набранный текст остаётся
// в поле. Проверяется поведение (нет результата, текст на месте), не текст
// сообщения (AGENTS.md).

class _Host {
  CustomRuleEditResult? result;
  bool closed = false;
}

Future<_Host> _open(WidgetTester tester, CustomRule initial) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final host = _Host();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async {
            host.result = await openCustomRuleEditor(
              context,
              initial: initial,
              outboundOptions: const [],
              existingNames: const {},
            );
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

Finder get _appBarSave => find.descendant(
      of: find.byType(AppBar),
      matching: find.widgetWithIcon(IconButton, Icons.save),
    );

Finder get _jsonField => find.byWidgetPredicate(
      (w) => w is TextField && w.maxLines == 20,
    );

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(_jsonField).controller!.text;

void main() {
  const valid = '{"domain":"a.test","action":"reject"}';

  for (final (label, body) in [
    ('массив', '[{"domain":"a.test","action":"reject"},'
        '{"domain":"b.test","action":"reject"}]'),
    ('невалидный JSON', '{"domain":"c.test",'),
  ]) {
    testWidgets('$label: Save в AppBar заблокирован, текст на месте',
        (tester) async {
      final host = await _open(
          tester, CustomRuleJson(id: 'r1', name: 'Rule 2', json: valid));

      await tester.enterText(_jsonField, body);
      await tester.pump();

      expect(tester.widget<IconButton>(_appBarSave).onPressed, isNull,
          reason: 'кнопка AppBar блокируется как кнопка формы');
      await tester.tap(_appBarSave, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(host.closed, isFalse, reason: 'редактор не закрылся');
      expect(host.result, isNull);
      expect(_fieldText(tester), body, reason: 'набранный текст не теряется');
    });

    testWidgets('$label: Save из диалога несохранённых правок не сохраняет',
        (tester) async {
      final host = await _open(
          tester, CustomRuleJson(id: 'r1', name: 'Rule 2', json: valid));

      await tester.enterText(_jsonField, body);
      await tester.pump();

      await tester.tap(find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.arrow_back),
      ));
      await tester.pumpAndSettle();
      // Диалог «Save / Keep editing / Discard» — кнопка сохранения.
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Save'),
      ));
      await tester.pumpAndSettle();

      expect(host.closed, isFalse);
      expect(host.result, isNull);
      expect(_fieldText(tester), body);
    });
  }

  testWidgets('валидный объект: Save в AppBar сохраняет', (tester) async {
    final host = await _open(
        tester, CustomRuleJson(id: 'r1', name: 'Rule 2', json: valid));

    const edited = '{"domain":"d.test","action":"reject"}';
    await tester.enterText(_jsonField, edited);
    await tester.pump();

    expect(tester.widget<IconButton>(_appBarSave).onPressed, isNotNull);
    await tester.tap(_appBarSave);
    await tester.pumpAndSettle();

    expect(host.closed, isTrue);
    expect(host.result?.saved?.json, edited);
  });
}
