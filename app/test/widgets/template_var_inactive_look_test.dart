import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/widgets/template_var_list.dart';
import 'package:lxbox/widgets/var_values_model.dart';

/// §743 — строка, выключенная своим `#enable`, показывает, что настройка не
/// действует: переключатель стоит в «выкл», список — «Not in effect».
/// Сохранённое значение при этом не меняется.
void main() {
  const gate = [
    {
      '#not': {'@master': 'off'}
    }
  ];

  final vars = <WizardVar>[
    WizardVar(
      name: 'master',
      type: 'enum',
      defaultValue: 'off',
      wizardUI: 'edit',
      options: const [
        WizardOption(value: 'off', title: 'Off'),
        WizardOption(value: '30s', title: '30 seconds'),
      ],
    ),
    WizardVar(
      name: 'lazy',
      type: 'bool',
      defaultValue: 'true',
      wizardUI: 'edit',
      enable: gate,
    ),
    WizardVar(
      name: 'limit',
      type: 'int',
      defaultValue: '12',
      wizardUI: 'edit',
      enable: gate,
      options: const [
        WizardOption(value: '5', title: '5'),
        WizardOption(value: '12', title: '12'),
      ],
    ),
  ];

  Future<VarValuesModel> pump(WidgetTester tester) async {
    final model = VarValuesModel({for (final v in vars) v.name: v.defaultValue});
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: LocaleController.supportedLocales,
      home: Scaffold(
        body: TemplateVarListView(
          vars: vars,
          model: model,
          onChanged: (_, _) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return model;
  }

  DropdownButton<String> limitDropdown(WidgetTester tester) =>
      tester.widget<DropdownButton<String>>(
          find.byKey(const ValueKey('options-limit')));

  testWidgets('условие ложно — переключатель «выкл», список «Not in effect»',
      (tester) async {
    final model = await pump(tester);

    final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(sw.value, isFalse, reason: 'сохранено true, но настройка не действует');
    expect(limitDropdown(tester).value, isNull);
    expect(find.text('Not in effect'), findsOneWidget);
    expect(find.text('12'), findsNothing);

    // Сохранённые значения не тронуты.
    expect(model.snapshot['lazy'], 'true');
    expect(model.snapshot['limit'], '12');
  });

  testWidgets('условие стало истинным — возвращаются сохранённые значения',
      (tester) async {
    final model = await pump(tester);
    model.set('master', '30s');
    await tester.pumpAndSettle();

    final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(sw.value, isTrue);
    expect(limitDropdown(tester).value, '12');
    expect(find.text('Not in effect'), findsNothing);
  });
}
