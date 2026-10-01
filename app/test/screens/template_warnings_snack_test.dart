import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/home/widgets/template_warnings_snack.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warnings_sheet.dart';
import 'package:lxbox/services/builder/if_engine.dart' show TemplateWarning;

/// §555 / задача 570 — поверхность `template_degraded` на Home: снек со
/// счётчиком и переход в шторку кодов.
void main() {
  Future<void> pump(WidgetTester tester, List<TemplateWarning> items) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showTemplateWarningsSnack(ctx, items),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  testWidgets('N предупреждений — снек, кнопка открывает шторку',
      (tester) async {
    await pump(tester, const [
      TemplateWarning('template_var_undeclared', {'name': 'a'}),
      TemplateWarning('template_var_undeclared', {'name': 'b'}),
    ]);
    expect(find.byKey(const ValueKey('template-warnings-snack')),
        findsOneWidget);
    await tester.tap(find.byType(SnackBarAction));
    await tester.pumpAndSettle();
    expect(find.byType(NodeWarningsSheet), findsOneWidget);
    expect(find.text('Template'), findsOneWidget);
  });

  testWidgets('пустой список — снека нет', (tester) async {
    await pump(tester, const []);
    expect(find.byType(SnackBar), findsNothing);
  });
}
