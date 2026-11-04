import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/widgets/template_var_list.dart';
import 'package:lxbox/widgets/var_values_model.dart';

/// SPEC 393 фаза D (D1/D2) — ТОЧЕЧНОСТЬ перерисовки списка настроек шаблона.
///
/// Эталон — лаунчер (`ui/configurator/tabs/settings_reactive.go`): изменение
/// переменной обновляет ТОЛЬКО подписанные на неё строки, остальные виджеты не
/// трогаются. У лаунчера для этого понадобился статический индекс
/// `переменная → строки` поверх `CondDeps`, потому что там строка зависит от
/// гейта (условия), а не только от собственного значения.
///
/// У LxBox условных гейтов на строках НЕТ (`WizardVar` не несёт ни `if`, ни
/// `#enable`), поэтому зависимость строки ровно одна — её собственный ключ, и
/// индексом служит сам per-key `ValueNotifier` модели (§232). Этот файл держит
/// свойство под наблюдением: если гейты появятся или подписка поедет на общий
/// `setState`, тесты покраснеют.
///
/// Проверяется МЕХАНИЗМ (что перестроилось), а не вёрстка и не тексты.

void main() {
  Future<VarValuesModel> pump(
    WidgetTester tester,
    List<WizardVar> vars,
  ) async {
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

  final vars = <WizardVar>[
    WizardVar(name: 'alpha', type: 'bool', defaultValue: 'false'),
    WizardVar(name: 'beta', type: 'bool', defaultValue: 'false'),
    WizardVar(name: 'gamma', type: 'bool', defaultValue: 'false'),
  ];

  group('D1/D2 — изменение переменной перестраивает только её строку', () {
    testWidgets('запись того же значения не перестраивает ничего',
        (tester) async {
      final model = await pump(tester, vars);
      final before =
          tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).toList();

      // VarValuesModel.set возвращает false и не уведомляет, если значение
      // не изменилось (fixpoint-guard, на нём же обрывается каскад on_change).
      expect(model.set('beta', 'false'), isFalse);
      await tester.pump();

      final after =
          tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).toList();
      for (var i = 0; i < before.length; i++) {
        expect(identical(before[i], after[i]), isTrue,
            reason: 'запись прежнего значения вызвала перерисовку строки $i');
      }
    });
  });
}
