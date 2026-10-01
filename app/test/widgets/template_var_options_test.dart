import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/widgets/template_var_list.dart';
import 'package:lxbox/widgets/var_values_model.dart';

/// §555 / задача 570 — `options` и `options_open` в редакторе переменных
/// (TEMPLATE_LANG §2.1, SPEC 143 D-125): `text_list` + `options` —
/// множественный выбор; `options_open` — своё значение сверх списка;
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
  testWidgets('text_list + options — чипы, значение по строке в порядке options',
      (tester) async {
    final got = <String, String>{};
    await _pump(tester,
        v: _var('text_list'), value: 'c', onChanged: (n, v) => got[n] = v);
    expect(find.byType(FilterChip), findsNWidgets(3));
    expect(find.byType(TextField), findsNothing); // закрытый список
    await tester.tap(find.byKey(const ValueKey('multi-x-a')));
    await tester.pumpAndSettle();
    expect(got['x'], 'a\nc');
  });

  testWidgets('text_list + options_open — свои строки после выбранных',
      (tester) async {
    final got = <String, String>{};
    await _pump(tester,
        v: _var('text_list', open: true),
        value: 'b\nzzz',
        onChanged: (n, v) => got[n] = v);
    expect(find.text('zzz'), findsOneWidget); // своё значение в поле
    await tester.enterText(find.byType(TextField), 'zzz\n  yyy ');
    await tester.pumpAndSettle();
    expect(got['x'], 'b\nzzz\nyyy');
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
