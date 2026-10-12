import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/screens/dns_settings_screen/user_rule_edit_screen.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';

// §626 ревизия 2 — полноэкранный редактор DNS-правила: создание, правка,
// Save, битый JSON, Back с правкой → диалог Unsaved changes, без правки —
// выход без диалога.

const _existing = DnsRuleInline(
  name: 'ru',
  rule: {'rule_set': 'geoip-ru', 'server': 'yandex_doh'},
  enabled: false,
);

void main() {
  late List<DnsRuleInline?> results;

  Future<void> open(WidgetTester tester, {DnsRuleInline? existing}) async {
    results = [];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async =>
                results.add(await openUserRuleEditor(context, existing: existing)),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  bool screenOpen() => find.byType(UserRuleEditScreen).evaluate().isNotEmpty;
  Finder nameField() => find.widgetWithText(TextField, 'Name');
  Finder unsaved() => find.text('Unsaved changes');
  TextEditingController bodyCtrl(WidgetTester tester) =>
      tester.widget<LxTextCodeField>(find.byType(LxTextCodeField)).controller;

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  testWidgets('новое правило: заголовок Add, заготовка, Save отдаёт правило',
      (tester) async {
    await open(tester);
    expect(find.text('Add DNS Rule'), findsOneWidget);
    await tester.enterText(nameField(), 'new');
    await save(tester);
    expect(screenOpen(), isFalse);
    expect(results.single?.name, 'new');
    expect(results.single?.rule['server'], 'yandex_doh');
    expect(results.single?.enabled, isTrue);
  });

  testWidgets('правка: Save отдаёт новое тело, enabled сохраняется',
      (tester) async {
    await open(tester, existing: _existing);
    expect(find.text('Edit DNS Rule'), findsOneWidget);
    bodyCtrl(tester).text = '{"domain_suffix": ["ru"], "server": "x"}';
    await tester.pump();
    await save(tester);
    expect(results.single?.name, 'ru');
    expect(results.single?.rule, {'domain_suffix': ['ru'], 'server': 'x'});
    expect(results.single?.enabled, isFalse);
  });

  testWidgets('битый JSON — ошибка, экран остаётся', (tester) async {
    await open(tester, existing: _existing);
    bodyCtrl(tester).text = '{oops';
    await tester.pump();
    await save(tester);
    expect(screenOpen(), isTrue);
    expect(find.textContaining('Invalid JSON'), findsOneWidget);
    expect(results, isEmpty);
  });

  testWidgets('пустое имя — ошибка, экран остаётся', (tester) async {
    await open(tester, existing: _existing);
    await tester.enterText(nameField(), '  ');
    await save(tester);
    expect(screenOpen(), isTrue);
    expect(find.text('Name is required'), findsOneWidget);
  });

  testWidgets('Back без правок — выход без диалога', (tester) async {
    await open(tester, existing: _existing);
    await back(tester);
    expect(unsaved(), findsNothing);
    expect(screenOpen(), isFalse);
    expect(results.single, isNull);
  });

  testWidgets('Back с правкой → диалог; Keep остаётся, Discard выходит',
      (tester) async {
    await open(tester, existing: _existing);
    await tester.enterText(nameField(), 'ru2');
    await back(tester);
    expect(unsaved(), findsOneWidget);
    await choose(tester, 'Keep');
    expect(screenOpen(), isTrue);
    expect(find.widgetWithText(TextField, 'ru2'), findsOneWidget);

    await back(tester);
    await choose(tester, 'Discard');
    expect(screenOpen(), isFalse);
    expect(results.single, isNull);
  });

  testWidgets('Back с правкой → Save из диалога сохраняет', (tester) async {
    await open(tester, existing: _existing);
    await tester.enterText(nameField(), 'ru2');
    await back(tester);
    await choose(tester, 'Save');
    expect(screenOpen(), isFalse);
    expect(results.single?.name, 'ru2');
  });
}
