import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/widgets/template_var_list.dart';
import 'package:lxbox/widgets/var_values_model.dart';

/// §555 / задача 570 — `options` и `options_open` в редакторе переменных
/// (TEMPLATE_LANG §2.1, SPEC 143 D-125): `text_list` + `options` —
/// множественный выбор; с `options_open` — комбобокс (поле + ▾, §691);
/// закрытые `options` у `text` — только выбор из списка.
Future<void> _pump(
  WidgetTester tester, {
  required WizardVar v,
  required String value,
  required void Function(String, String) onChanged,
}) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: LocaleController.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: TemplateVarListView(
          vars: [v],
          model: VarValuesModel({v.name: value}),
          onChanged: onChanged,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

WizardVar _var(String type, {bool open = false, String def = ''}) =>
    WizardVar.fromJson({
      'name': 'x',
      'type': type,
      'default_value': def,
      'options': ['a', 'b', 'c'],
      if (open) 'options_open': true,
    });

void main() {
  testWidgets(
      'text_list + options — теги выбранных с ×, «Add ▾» с остальными (§709)',
      (tester) async {
    final got = <String, String>{};
    await _pump(tester,
        v: _var('text_list'), value: 'c\nzzz', onChanged: (n, v) => got[n] = v);
    // Только выбранные — тегами; чужое «zzz» не показывается.
    expect(find.byType(InputChip), findsOneWidget);
    expect(find.byKey(const ValueKey('chip-x-c')), findsOneWidget);
    expect(find.byType(TextField), findsNothing); // своего ввода нет
    // Добавление через ▾: в меню только невыбранные.
    await tester.tap(find.byKey(const ValueKey('chip-add-x')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(PopupMenuItem<String>, 'c'), findsNothing);
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'a'));
    await tester.pumpAndSettle();
    expect(got['x'], 'c\na'); // порядок добавления, «zzz» выпало
  });

  testWidgets('text_list + options — × снимает тег, пустое = «Core default»',
      (tester) async {
    final got = <String, String>{};
    await _pump(tester,
        v: _var('text_list'), value: 'b', onChanged: (n, v) => got[n] = v);
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('chip-x-b')),
        matching: find.byType(Icon)));
    await tester.pumpAndSettle();
    expect(got['x'], '');
    await _pump(tester,
        v: _var('text_list'), value: '', onChanged: (n, v) => got[n] = v);
    expect(find.byType(InputChip), findsNothing);
    expect(find.text('Core default'), findsOneWidget);
  });

  // §691 — правило UX: строка/мультистрока с подсказками — комбобокс
  // (поле + стрелка списка), не чипы.
  testWidgets(
      'text_list + options_open — комбобокс: поле, ▾ добавляет и убирает строку',
      (tester) async {
    final got = <String, String>{};
    await _pump(tester,
        v: _var('text_list', open: true),
        value: 'b\nzzz',
        onChanged: (n, v) => got[n] = v);
    expect(find.byType(FilterChip), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('b\nzzz'), findsOneWidget); // всё значение — в поле

    // Выбор подсказки, которой нет, — строка в конец.
    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pumpAndSettle();
    await tester.tap(find.text('a').last);
    await tester.pumpAndSettle();
    expect(got['x'], 'b\nzzz\na');

    // Повторный выбор уже добавленной — строка убирается.
    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pumpAndSettle();
    await tester.tap(find.text('b').last);
    await tester.pumpAndSettle();
    expect(got['x'], 'zzz\na');
  });

  testWidgets('text + закрытые options — dropdown, свободного ввода нет',
      (tester) async {
    await _pump(tester,
        v: _var('text', def: 'b'), value: 'b', onChanged: (_, _) {});
    expect(find.byKey(const ValueKey('options-x')), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('int + options_open — своё значение с приведением по type',
      (tester) async {
    final got = <String, String>{};
    await _pump(tester,
        v: WizardVar.fromJson({
          'name': 'x',
          'type': 'int',
          'default_value': '1400',
          'options': ['1280', '1400'],
          'options_open': true,
        }),
        value: '1400',
        onChanged: (n, v) => got[n] = v);
    await tester.enterText(find.byType(TextField), '99999');
    await tester.pumpAndSettle();
    expect(got['x'], '65535');
  });
}
