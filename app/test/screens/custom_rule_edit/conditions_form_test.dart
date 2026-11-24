import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/rule_tree.dart';
import 'package:lxbox/screens/custom_rule_edit/cond_stack.dart';
import 'package:lxbox/screens/custom_rule_edit/edit_controller.dart';
import 'package:lxbox/screens/custom_rule_edit/sections/conditions_section.dart'
    show SubRuleScreen;
import 'package:lxbox/screens/custom_rule_edit/sections/dns_resolve_section.dart';
import 'package:lxbox/screens/custom_rule_edit/sections/json_section.dart';
import 'package:lxbox/screens/custom_rule_edit_screen.dart';

// §757 волна 4 — форма правила из условий: «+ Condition», удаление рамки,
// группа all of / any of / Not, под-правило отдельным экраном, наборы в
// Destination, круг «дерево → форма → дерево», уход из JSON-вида.
// Проверяется поведение (сохранённое правило, дерево), не тексты.

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

Finder _field(String key) => find.descendant(
      of: find.byKey(ValueKey('$key#field')),
      matching: find.byType(TextField),
    );

/// Рамка условия, в label-декорации которой (разрыв рамки) есть [part].
Finder _frameLabelled(String part) => find.byWidgetPredicate((w) {
      if (w is! InputDecorator) return false;
      final l = w.decoration.label;
      return l is Text && (l.textSpan?.toPlainText() ?? '').contains(part);
    });

Future<void> _addCondition(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text('Condition').last);
  await tester.tap(find.text('Condition').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<CustomRuleTree> _save(WidgetTester tester, _Host host) async {
  await tester.tap(_appBarSave);
  await tester.pumpAndSettle();
  expect(host.closed, isTrue);
  return host.result!.saved! as CustomRuleTree;
}

String _bodyKey(RuleNode n) =>
    jsonEncode(ruleTreeBodyToJson(RuleTreeBody(root: n)));

CustomRuleEditController _ctrl(CustomRule r) => CustomRuleEditController(
      initial: r,
      preset: null,
      existingNames: const {},
    );

final _domainRule = CustomRuleTree.flat(
  id: 'r1',
  name: 'R',
  domains: ['a.test'],
  outbound: 'direct-out',
);

void main() {
  testWidgets('+ Condition: условие появляется рамкой и уходит из меню',
      (tester) async {
    final host = await _open(tester, _domainRule);
    await _addCondition(tester, 'Port');
    await tester.enterText(_field('port'), '443, 8443');
    await tester.pump();

    await tester.tap(find.text('Condition').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(PopupMenuItem<String>, 'Port'), findsNothing);
    expect(find.widgetWithText(PopupMenuItem<String>, 'Protocol'),
        findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    final saved = await _save(tester, host);
    expect(saved.ports, ['443', '8443']);
    expect(saved.domains, ['a.test']);
  });

  testWidgets('✕ заполненной рамки — после подтверждения, условие уходит',
      (tester) async {
    final host = await _open(tester, _domainRule);
    await _addCondition(tester, 'Port');
    await tester.enterText(_field('port'), '443');
    await tester.pump();

    // Рамка Port — вторая: ✕ рамок по порядку.
    await tester.tap(find.byIcon(Icons.close).at(1));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    expect(_field('port'), findsNothing);

    final saved = await _save(tester, host);
    expect(saved.ports, isEmpty);
  });

  testWidgets('название и связка — в разрыве рамки; ✕ рамки удаляет условие',
      (tester) async {
    final host = await _open(tester, _domainRule);
    final dest = _frameLabelled('Destination / Rule sets');
    expect(dest, findsOneWidget);
    expect(_frameLabelled('any of'), findsOneWidget);

    await _addCondition(tester, 'Rule group');
    final group = _frameLabelled('Rule group');
    expect(group, findsOneWidget);
    expect(_frameLabelled('all of'), findsOneWidget);
    await tester.tap(find.text('any of').last);
    await tester.pump();
    expect(_frameLabelled('all of'), findsNothing);
    expect(_frameLabelled('any of'), findsNWidgets(2));

    // ✕ внутри рамки Destination — после подтверждения условие уходит.
    await tester.tap(find
        .descendant(of: dest, matching: find.byIcon(Icons.close))
        .last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    expect(dest, findsNothing);
    expect(_field('domain'), findsNothing);

    // Пустая группа — без вопроса.
    await tester.tap(find
        .descendant(of: group, matching: find.byIcon(Icons.close))
        .last);
    await tester.pumpAndSettle();
    expect(group, findsNothing);
    expect(host.closed, isFalse);
  });

  testWidgets('группа any of + Not, под-правило отдельным экраном',
      (tester) async {
    final host = await _open(tester, _domainRule);
    await _addCondition(tester, 'Rule group');
    await tester.tap(find.text('any of').last);
    await tester.pump();
    await tester.tap(find.text('Not'));
    await tester.pump();

    // Под-правило — тот же редактор стопки на своём экране.
    await tester.tap(find.text('Rule 1'));
    await tester.pumpAndSettle();
    expect(find.byType(SubRuleScreen), findsOneWidget);
    await _addCondition(tester, 'Destination / Rule sets');
    await tester.enterText(_field('domain_suffix'), 'b.test');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(SubRuleScreen), findsNothing);

    final saved = await _save(tester, host);
    final root = saved.root as RuleGroup;
    expect(root.mode, RuleGroup.kAnd);
    expect((root.children.first as RuleLeaf).conditions['domain'],
        ['a.test']);
    final g = root.children[1] as RuleGroup;
    expect(g.mode, RuleGroup.kOr);
    expect(g.invert, isTrue);
    expect((g.children.single as RuleLeaf).conditions['domain_suffix'],
        ['b.test']);
  });

  testWidgets('наборы — поле внутри Destination; правило становится srs',
      (tester) async {
    final host = await _open(tester, _domainRule);
    await tester.enterText(_field('refs'), 'https://example.com/a.srs');
    await tester.pump();
    expect(find.text('Rule sets'), findsOneWidget);

    final saved = await _save(tester, host);
    expect(saved.kind, CustomRuleKind.srs);
    expect(saved.allRefs, ['https://example.com/a.srs']);
    expect(saved.domains, ['a.test'], reason: 'домены рядом с набором');
  });

  testWidgets('правило без условий не сохраняется', (tester) async {
    await _open(tester, CustomRuleTree.flat(id: 'n', name: 'New'));
    expect(tester.widget<IconButton>(_appBarSave).onPressed, isNull);
    await _addCondition(tester, 'Network');
    await tester.tap(find.widgetWithText(FilterChip, 'udp'));
    await tester.pump();
    expect(tester.widget<IconButton>(_appBarSave).onPressed, isNotNull);
  });

  group('круг дерево → форма → дерево', () {
    final nested = CustomRuleTree(
      id: 't1',
      name: 'T',
      outbound: 'vpn-1',
      root: const RuleGroup(mode: RuleGroup.kAnd, children: [
        RuleLeaf(conditions: {
          'domain_suffix': ['a.test'],
          'port': [443],
        }, refs: ['https://x/a.srs']),
        RuleGroup(mode: RuleGroup.kOr, invert: true, children: [
          RuleLeaf(conditions: {
            'network': ['udp'],
          }),
          RuleGroup(mode: RuleGroup.kAnd, children: [
            RuleLeaf(conditions: {
              'package_name': ['com.x'],
            }),
            RuleLeaf(invert: true, conditions: {
              'process_name': ['y'],
            }),
          ]),
        ]),
      ]),
    );

    test('открытое без правок — то же правило, не грязное', () {
      final c = _ctrl(nested);
      addTearDown(c.dispose);
      expect(c.jsonMode, isFalse);
      expect([for (final f in c.stack.frames) f.cond.id],
          ['destination', 'port']);
      expect(c.stack.groups.single.any, isTrue);
      expect(c.snapshot(), nested);
      expect(c.isDirty(), isFalse);
    });

    test('стопка → узел → стопка → узел даёт то же дерево', () {
      final s1 = CondStack.fromNode(nested.root, ruleConditionTable)!;
      final n1 = s1.toNode()!;
      final s2 = CondStack.fromNode(n1, ruleConditionTable)!;
      expect(_bodyKey(s2.toNode()!), _bodyKey(n1));
      expect(_bodyKey(n1), _bodyKey(nested.root));
    });

    test('Not простого правила — группа all of с Not', () {
      final s = CondStack.fromNode(
          const RuleLeaf(invert: true, conditions: {
            'domain': ['a.test'],
          }),
          ruleConditionTable)!;
      expect(s.frames, isEmpty);
      final g = s.groups.single;
      expect(g.not, isTrue);
      expect(g.any, isFalse);
      // Обратно — то же простое правило с `invert`.
      final n = s.toNode()! as RuleLeaf;
      expect(n.invert, isTrue);
      expect(n.conditions['domain'], ['a.test']);
    });

    test('под-правило в под-правиле — без предела глубины', () {
      final c = _ctrl(_domainRule);
      addTearDown(c.dispose);
      var s = c.stack;
      for (var i = 0; i < 4; i++) {
        final g = c.addGroup(s);
        s = g.rules.single;
      }
      c.addCondition(s, c.table.condition('port')!);
      c.setFieldRaw(s.frame('port')!, 'port', '53');
      var n = (c.snapshot() as CustomRuleTree).root;
      var depth = 0;
      while (n is RuleGroup) {
        n = n.children.last;
        depth++;
      }
      // Корень `and` (условия + группа) и четыре вложенные группы.
      expect(depth, 5);
      expect((n as RuleLeaf).conditions['port'], [53]);
    });

    test('пустые рамки и группы не пишутся', () {
      final c = _ctrl(_domainRule);
      addTearDown(c.dispose);
      c.addCondition(c.stack, c.table.condition('port')!);
      c.addGroup(c.stack);
      expect(c.snapshot(), _domainRule);
      expect(c.isDirty(), isFalse);
    });
  });

  group('JSON-вид', () {
    test('уход из JSON раскладывает тело в форму и цель в Action', () {
      final c = _ctrl(_domainRule);
      addTearDown(c.dispose);
      c.enterJsonMode();
      expect(c.kind, CustomRuleKind.json);
      c.jsonCtrl.text = jsonEncode({
        'type': 'logical',
        'mode': 'or',
        'rules': [
          {'domain': 'a.test'},
          {'port': 53},
        ],
        'outbound': 'vpn-2',
      });
      expect(c.applyJsonToForm(), isNull);
      expect(c.jsonMode, isFalse);
      expect(c.outbound, 'vpn-2');
      expect(c.stack.groups.single.any, isTrue);
      final root = (c.snapshot() as CustomRuleTree).root as RuleGroup;
      expect(root.mode, RuleGroup.kOr);
    });

    test('тело, которое форма не покажет, — причина; Discard — в форму', () {
      final c = _ctrl(_domainRule);
      addTearDown(c.dispose);
      c.enterJsonMode();
      c.jsonCtrl.text = '{"process_name": "a", "process_path": "/b"}';
      expect(c.applyJsonToForm(), isNotNull);
      expect(c.jsonMode, isTrue);
      expect(c.discardJson(), isTrue);
      expect(c.jsonMode, isFalse);
      expect(c.snapshot(), _domainRule);
    });

    test('json-правило остаётся json-правилом, пока не разложено', () {
      final r = CustomRuleJson(
          id: 'j', name: 'J', json: '{"domain": "a.test", "outbound": "x"}');
      final c = _ctrl(r);
      addTearDown(c.dispose);
      expect(c.jsonMode, isTrue);
      expect(c.snapshot(), r);
      expect(c.discardJson(), isFalse, reason: 'формы нет');
      expect(c.applyJsonToForm(), isNull);
      expect(c.snapshot(), isA<CustomRuleTree>());
    });
  });

  group('вкладка DNS', () {
    Finder tab(String t) => find.widgetWithText(Tab, t);

    testWidgets('блок DNS & Resolve — на вкладке DNS, в Params его нет',
        (tester) async {
      await _open(tester, _domainRule);
      expect(find.byType(DnsResolveSection), findsNothing);
      await tester.tap(tab('DNS'));
      await tester.pumpAndSettle();
      expect(find.byType(DnsResolveSection), findsOneWidget);
    });

    testWidgets('из Raw JSON с ошибкой — Discard / Keep editing',
        (tester) async {
      await _open(tester, _domainRule);
      await tester.tap(find.text('Raw JSON'));
      await tester.pumpAndSettle();
      final json = tester.widget<JsonSection>(find.byType(JsonSection));
      json.controller.text = '{bad';
      json.onChanged();
      await tester.pump();

      await tester.tap(tab('DNS'));
      await tester.pumpAndSettle();
      expect(find.text('Discard'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.byType(JsonSection), findsOneWidget,
          reason: 'назад на Params, JSON не тронут');
      expect(json.controller.text, '{bad');

      await tester.tap(tab('DNS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(DnsResolveSection), findsOneWidget);
    });

    testWidgets('корректный JSON раскладывается до перехода на DNS',
        (tester) async {
      await _open(tester, CustomRuleTree.flat(
          id: 'n', name: 'N', ports: ['443'], outbound: 'direct-out'));
      await tester.tap(find.text('Raw JSON'));
      await tester.pumpAndSettle();
      final json = tester.widget<JsonSection>(find.byType(JsonSection));
      json.controller.text = '{"domain_suffix": ["a.test"]}';
      json.onChanged();
      await tester.pump();

      await tester.tap(tab('DNS'));
      await tester.pumpAndSettle();
      expect(find.text('Discard'), findsNothing);
      expect(find.byType(DnsResolveSection), findsOneWidget,
          reason: 'домен из JSON виден DNS-вкладке');
    });
  });
}
