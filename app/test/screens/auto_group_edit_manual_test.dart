import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/screens/auto_group_edit_screen.dart';
import 'package:lxbox/services/contract/group_genus.dart';

// §565 — группа ручного рода (selector): редактор показывает членов пула с
// отметкой выбранного, выбор члена меняет `default`. Проверяется поведение,
// не текст (AGENTS.md).

const _a = NodeLink(folderId: 'f1', tag: 'A');
const _b = NodeLink(folderId: 'f1', tag: 'B');

Future<void> _open(WidgetTester tester, AutoSelectSpec initial) async {
  tester.view.physicalSize = const Size(900, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          await Navigator.push<AutoGroupEditResult>(
            context,
            MaterialPageRoute(
              builder: (_) => AutoGroupEditScreen(
                initial: initial,
                candidates: const [
                  (key: _a, label: 'Alpha'),
                  (key: _b, label: 'Beta'),
                ],
                canDelete: false,
              ),
            ),
          );
        },
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.check));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('выбор члена ручной группы меняет default', (tester) async {
    AutoGroupEditResult? got;
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final initial = AutoSelectSpec(
      id: 'g',
      tag: 'Pick',
      label: 'Pick',
      genus: GroupGenus.manual,
      membership: const ExplicitMembers([_a, _b]),
      manualDefault: 'A',
    );
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            got = await Navigator.push<AutoGroupEditResult>(
              context,
              MaterialPageRoute(
                builder: (_) => AutoGroupEditScreen(
                  initial: initial,
                  candidates: const [
                    (key: _a, label: 'Alpha'),
                    (key: _b, label: 'Beta'),
                  ],
                  canDelete: false,
                ),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final radioA = find.byKey(const ValueKey('auto-group-default-A'));
    final radioB = find.byKey(const ValueKey('auto-group-default-B'));
    expect(radioA, findsOneWidget);
    expect(radioB, findsOneWidget);
    expect(tester.widget<RadioListTile<String>>(radioA).value, 'A');

    await tester.tap(radioB);
    await tester.pumpAndSettle();
    await _save(tester);

    final saved = (got! as AutoGroupSaved).spec;
    expect(saved.isManual, isTrue);
    expect(saved.manualDefault, 'B');
    expect(saved.membership, const ExplicitMembers([_a, _b]));
  });

  testWidgets('группа автовыбора: списка выбора нет, род сохраняется',
      (tester) async {
    await _open(
      tester,
      AutoSelectSpec(id: 'g', tag: 'Auto', label: 'Auto'),
    );
    expect(find.byKey(const ValueKey('auto-group-default-A')), findsNothing);
  });

  testWidgets('переключение в ручной режим даёт род selector',
      (tester) async {
    AutoGroupEditResult? got;
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            got = await Navigator.push<AutoGroupEditResult>(
              context,
              MaterialPageRoute(
                builder: (_) => AutoGroupEditScreen(
                  initial:
                      AutoSelectSpec(id: 'g', tag: 'Auto', label: 'Auto'),
                  candidates: const [
                    (key: _a, label: 'Alpha'),
                    (key: _b, label: 'Beta'),
                  ],
                  canDelete: false,
                ),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.touch_app_outlined));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('auto-group-default-A')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('auto-group-default-B')));
    await tester.pumpAndSettle();
    await _save(tester);

    final saved = (got! as AutoGroupSaved).spec;
    expect(saved.genus, GroupGenus.manual);
    expect(saved.manualDefault, 'B');
  });
}
