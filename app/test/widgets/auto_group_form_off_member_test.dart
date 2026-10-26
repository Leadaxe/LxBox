import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/widgets/auto_group_form.dart';

// §686 — превью состава auto-узла: выключенный в папке член виден со своей
// иконкой ⏻ (в All/Rule на месте ✓/⊖, в Pick рядом с чекбоксом), в «N of M»
// не входит, к счёту — «· K off»; в Pick его можно отметить, выбор хранится.

const _p = NodeLink(folderId: 'f1', tag: 'P');
const _xc = NodeLink(folderId: 'f1', tag: 'Xc');
const _xcu = NodeLink(folderId: 'f1', tag: 'Xcu');
const _xd = NodeLink(folderId: 'f1', tag: 'Xd');

const _candidates = [
  AutoPoolCandidate(key: _p, label: 'P: Plain WG', enabled: false),
  AutoPoolCandidate(key: _xc, label: 'Xc: Chrome'),
  AutoPoolCandidate(key: _xcu, label: 'Xcu: Curl'),
  AutoPoolCandidate(key: _xd, label: 'Xd: DNS'),
];

Future<List<AutoSelectSpec>> _pump(
    WidgetTester tester, AutoSelectMembership m) async {
  tester.view.physicalSize = const Size(900, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final changes = <AutoSelectSpec>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ListView(children: [
        AutoGroupForm(
          value: AutoSelectSpec(id: 'g', tag: 'Auto', label: 'Auto', membership: m),
          candidates: _candidates,
          onChanged: changes.add,
        ),
      ]),
    ),
  ));
  await tester.pumpAndSettle();
  return changes;
}

String _count(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('auto-group-count'))).data!;

Finder _row(NodeLink l) => find.byKey(ValueKey('auto-group-member-${l.tag}'));
Finder _off(NodeLink l) => find.byKey(ValueKey('auto-group-off-${l.tag}'));

void main() {
  testWidgets('Rule: выключенный — ⏻ вместо ✓/⊖, вне счёта, «· 1 off»',
      (tester) async {
    await _pump(tester, const RuleMembers(exclude: 'Xcu'));
    expect(_count(tester), startsWith('2 of 3 '));
    expect(_count(tester), contains('1 off'));
    expect(_off(_p), findsOneWidget);
    expect(
        find.descendant(
            of: _row(_p), matching: find.byIcon(Icons.check_circle_outline)),
        findsNothing);
    expect(
        find.descendant(
            of: _row(_xcu),
            matching: find.byIcon(Icons.remove_circle_outline)),
        findsOneWidget);
    expect(_off(_xc), findsNothing);
  });

  testWidgets('All: в счёте только включённые', (tester) async {
    await _pump(tester, const RuleMembers());
    expect(_count(tester), startsWith('3 of 3 '));
    expect(_count(tester), contains('1 off'));
    expect(_off(_p), findsOneWidget);
  });

  testWidgets('Pick: выключенного можно отметить, ⏻ остаётся, вне счёта',
      (tester) async {
    final changes = await _pump(tester, const ExplicitMembers([_xc]));
    expect(_count(tester), startsWith('1 of 3 '));
    expect(_off(_p), findsOneWidget);

    await tester.tap(find.descendant(
        of: _row(_p), matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();
    expect(_off(_p), findsOneWidget);
    expect(_count(tester), startsWith('1 of 3 '),
        reason: 'выключенный в пул не входит');
    final m = changes.last.membership as ExplicitMembers;
    expect(m.members, [_p, _xc], reason: 'выбор хранится в порядке папки');
  });
}
