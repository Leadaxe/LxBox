import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/widgets/template_var_list.dart';

/// §161 — поведение пустых required-полей в [TemplateVarListView]:
///  - «UI сам чинит»: пустое required с непустым default → подставляется
///    default при загрузке (initState) и персистится через onChanged.
///  - пустое required нельзя сохранить: onChanged НЕ зовётся, показан errorText.
///  - optional (§033 required:false) и secret — не трогаются.

Future<void> _pump(
  WidgetTester tester, {
  required List<WizardVar> vars,
  required Map<String, String> initialValues,
  required void Function(String, String) onChanged,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: TemplateVarListView(
        vars: vars,
        initialValues: initialValues,
        onChanged: onChanged,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('§161 — self-repair при загрузке', () {
    testWidgets('пустое required с default → подставляется и персистится',
        (tester) async {
      final captured = <String, String>{};
      await _pump(
        tester,
        vars: [WizardVar(name: 'tol', type: 'int', defaultValue: '30')],
        initialValues: {'tol': ''}, // битое значение в storage
        onChanged: (n, v) => captured[n] = v,
      );
      // initState подставил default; post-frame персистнул в parent.
      expect(captured['tol'], '30');
      expect(find.text('30'), findsOneWidget); // показано в поле
    });

    testWidgets('optional (required:false) пустое → НЕ чинится', (tester) async {
      final captured = <String, String>{};
      await _pump(
        tester,
        vars: [
          WizardVar(
              name: 'opt',
              type: 'text',
              defaultValue: 'fallback',
              required: false),
        ],
        initialValues: {'opt': ''},
        onChanged: (n, v) => captured[n] = v,
      );
      expect(captured.containsKey('opt'), false); // ничего не персистнулось
    });

    testWidgets('secret пустое → НЕ чинится (стёртый пароль не воскрешаем)',
        (tester) async {
      final captured = <String, String>{};
      await _pump(
        tester,
        vars: [WizardVar(name: 'pw', type: 'secret', defaultValue: 'seed')],
        initialValues: {'pw': ''},
        onChanged: (n, v) => captured[n] = v,
      );
      expect(captured.containsKey('pw'), false);
    });
  });

  group('§161 — нельзя сохранить пустое required', () {
    testWidgets('стираем required-поле → onChanged НЕ зовётся + errorText',
        (tester) async {
      final captured = <String, String>{};
      await _pump(
        tester,
        vars: [WizardVar(name: 'tol', type: 'int', defaultValue: '30')],
        initialValues: {'tol': '50'}, // валидное стартовое
        onChanged: (n, v) => captured[n] = v,
      );
      captured.clear();
      // Стираем поле.
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pump();
      // Persist пустоты заблокирован.
      expect(captured.containsKey('tol'), false);
      // errorText показан.
      expect(find.text('Required'), findsOneWidget);
    });

    testWidgets('ввод валидного значения после пустого → персистится + ошибка снята',
        (tester) async {
      final captured = <String, String>{};
      await _pump(
        tester,
        vars: [WizardVar(name: 'tol', type: 'int', defaultValue: '30')],
        initialValues: {'tol': '50'},
        onChanged: (n, v) => captured[n] = v,
      );
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pump();
      expect(find.text('Required'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '40');
      await tester.pump();
      expect(captured['tol'], '40');
      expect(find.text('Required'), findsNothing);
    });
  });
}
