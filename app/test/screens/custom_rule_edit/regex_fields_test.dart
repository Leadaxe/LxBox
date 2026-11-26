import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/screens/custom_rule_edit_screen.dart';

// §712 / §757 — поле Package regex условия Apps в редакторе правила:
// регулярки по строке уходят в packageRegexes, битая регулярка блокирует
// Save. Проверяется поведение (результат сохранения, гейт кнопки, ошибка
// поля), не текст сообщений.

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

Finder _regexField() => find.descendant(
      of: find.byKey(const ValueKey('package_name_regex#field')),
      matching: find.byType(TextField),
    );

/// §757 — условие Apps добавляется из меню «+ Condition».
Future<void> _addApps(WidgetTester tester) async {
  await tester.tap(find.text('Condition'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Apps').last);
  await tester.pumpAndSettle();
}

void main() {
  final initial = CustomRuleTree.flat(
    id: 'r1',
    name: 'Oplus',
    domains: ['a.test'],
    outbound: 'direct-out',
  );

  testWidgets('две регулярки по строке → два элемента в правиле',
      (tester) async {
    final host = await _open(tester, initial);
    await _addApps(tester);
    await tester.ensureVisible(_regexField());
    // Запятая внутри регулярки не делит её на две.
    await tester.enterText(_regexField(), '^com\\.oplus\\.\n^a{1,3}\\.b\n');
    await tester.pump();

    expect(tester.widget<IconButton>(_appBarSave).onPressed, isNotNull);
    await tester.tap(_appBarSave);
    await tester.pumpAndSettle();

    expect(host.closed, isTrue);
    final saved = host.result?.saved as CustomRuleTree;
    expect(saved.packageRegexes, ['^com\\.oplus\\.', '^a{1,3}\\.b']);
    expect(saved.packages, isEmpty);
  });

  testWidgets('битая регулярка: Save заблокирован, поле в ошибке',
      (tester) async {
    final host = await _open(tester, initial);
    await _addApps(tester);
    await tester.ensureVisible(_regexField());
    await tester.enterText(_regexField(), '^com\\.oplus\\.\n(unclosed');
    await tester.pump();

    expect(tester.widget<IconButton>(_appBarSave).onPressed, isNull);
    // Поле показывает ошибку.
    expect(tester.widget<TextField>(_regexField()).decoration?.errorText,
        isNotNull);
    await tester.tap(_appBarSave, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(host.closed, isFalse);
    expect(host.result, isNull);
  });
}
