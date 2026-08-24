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

/// Счётчик перестроений: увеличивается на каждый build своего поддерева.
/// Пробная обёртка — вне продакшн-кода, живёт только в тесте.
class _BuildCounter extends StatelessWidget {
  const _BuildCounter({required this.tick, required this.child});

  final void Function() tick;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    tick();
    return child;
  }
}

/// Считает, сколько раз перестроился контрол каждой переменной.
///
/// Опора на механику Flutter: `ValueListenableBuilder` при уведомлении строит
/// НОВЫЙ экземпляр child-виджета. Если экземпляр тот же самый — поддерево не
/// перестраивалось. Сравниваем по `identical`, а не по значению полей.
Map<String, Object> _controlIdentities(WidgetTester tester, List<String> names) {
  final out = <String, Object>{};
  for (final n in names) {
    final f = find.byKey(ValueKey('probe-$n'));
    expect(f, findsOneWidget, reason: 'контрол переменной $n не найден');
    out[n] = tester.widget(f);
  }
  return out;
}

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
    testWidgets('соседние контролы не пересобираются', (tester) async {
      final model = await pump(tester, vars);

      // Каждый bool-контрол — SwitchListTile; ищем по позиции в списке.
      List<SwitchListTile> switches() => tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList();

      final before = switches();
      expect(before, hasLength(3));

      model.set('beta', 'true');
      await tester.pump();

      final after = switches();
      expect(after, hasLength(3));

      // Строка изменённой переменной — НОВЫЙ экземпляр (перестроилась).
      expect(identical(before[1], after[1]), isFalse,
          reason: 'строка изменённой переменной обязана перестроиться');
      // Соседи — те же экземпляры: их поддеревья Flutter не трогал.
      expect(identical(before[0], after[0]), isTrue,
          reason: 'строка соседней переменной перестроилась — подписка не '
              'точечная (общий setState вместо per-key)');
      expect(identical(before[2], after[2]), isTrue,
          reason: 'строка соседней переменной перестроилась — подписка не '
              'точечная (общий setState вместо per-key)');
    });

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

    testWidgets('каскад on_change по двум целям трогает ровно две строки',
        (tester) async {
      // Механика §232: parent пишет производные значения через model.set —
      // ровно то, что делает settings_screen._applyOnChange. Ни одна строка
      // вне множества целей перестраиваться не должна.
      final model = await pump(tester, vars);
      final before =
          tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).toList();

      model.set('alpha', 'true');
      model.set('gamma', 'true');
      await tester.pump();

      final after =
          tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).toList();
      expect(identical(before[0], after[0]), isFalse);
      expect(identical(before[2], after[2]), isFalse);
      expect(identical(before[1], after[1]), isTrue,
          reason: 'строка вне каскада перестроилась');
    });
  });

  group('D1/D2 — счётчик ребилдов', () {
    testWidgets('N изменений одной переменной = N перестроений её строки',
        (tester) async {
      // Прямой счётчик поверх той же модели: считаем не виджеты списка, а
      // сам механизм подписки — сколько раз слушатель ключа был уведомлён.
      final model = VarValuesModel({'alpha': 'false', 'beta': 'false'});
      final counts = <String, int>{'alpha': 0, 'beta': 0};

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final name in counts.keys)
                ValueListenableBuilder<String>(
                  valueListenable: model.notifier(name),
                  builder: (_, value, _) => _BuildCounter(
                    tick: () => counts[name] = counts[name]! + 1,
                    child: SizedBox(key: ValueKey('probe-$name')),
                  ),
                ),
            ],
          ),
        ),
      ));
      await tester.pump();
      final baseAlpha = counts['alpha']!;
      final baseBeta = counts['beta']!;
      expect(baseAlpha, greaterThan(0));

      model.set('alpha', 'true');
      await tester.pump();
      model.set('alpha', 'false');
      await tester.pump();
      model.set('alpha', 'true');
      await tester.pump();

      expect(counts['alpha']! - baseAlpha, 3,
          reason: 'три изменения — три перестроения, не больше и не меньше');
      expect(counts['beta']! - baseBeta, 0,
          reason: 'соседний ключ не должен получать уведомлений вовсе');

      // И обратное: проба находится там, где мы её ищем (страховка от
      // вырожденно-зелёного теста на несуществующем виджете).
      expect(_controlIdentities(tester, ['alpha', 'beta']).length, 2);
    });
  });
}
