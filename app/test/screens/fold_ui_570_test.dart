import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_replace.dart';
import 'package:lxbox/screens/direction_edit_screen.dart';
import 'package:lxbox/screens/source_replace_screen.dart';

/// §568 / задача 570 — UI свёртки: опция `include` Направления на группу
/// свёртки и предупреждение редактора свёртки о занятом имени.
void main() {
  Future<DirectionEditResult?> editDirection(
      WidgetTester tester, Direction initial) async {
    tester.view.physicalSize = const Size(900, 5000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    DirectionEditResult? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async {
            result = await openDirectionEditor(
              ctx,
              initial: initial,
              canDelete: true,
              allNodeTags: const [],
              foldCandidates: foldCandidatesOf(const [
                (name: 'My sub', replace: SourceReplace(mode: ReplaceMode.manual, tag: 'FOLD')),
                (name: 'Off', replace: null),
              ]),
            );
          },
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    final box = find.byKey(const ValueKey('direction-include-fold-FOLD'));
    expect(box, findsOneWidget);
    await tester.tap(box);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('Направление берёт свёртку опцией include', (tester) async {
    final r = await editDirection(tester, Direction(tag: 'vpn-2', label: 'X'));
    expect(r?.saved?.include, ['FOLD']);
  });

  test('занятые имена: узел другого источника, свёртка, Направление', () {
    final other = SubscriptionServers(
      id: 'o',
      name: 'o',
      enabled: true,
      tagPrefix: 'P:',
      detourPolicy: DetourPolicy.defaults,
      url: 'https://e.com',
      replace: const SourceReplace(mode: ReplaceMode.manual, tag: 'G2'),
    );
    final taken = replaceTagOwnersOf(
      sources: [other],
      selfId: 'me',
      directions: [Direction(tag: 'vpn-1', label: 'Main')],
    );
    expect(taken['G2'], ReplaceTagOwner.fold);
    expect(taken['vpn-1'], ReplaceTagOwner.direction);
    expect(replaceTagOwnersOf(sources: [other], selfId: 'o'), isEmpty);
  });

  testWidgets('редактор свёртки предупреждает о занятом имени, но сохраняет',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: SourceReplaceScreen(
        initial: SourceReplace(mode: ReplaceMode.manual, tag: 'vpn-1'),
        defaultTag: 'sub',
        takenTags: {'vpn-1': ReplaceTagOwner.direction},
      ),
    ));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.decoration?.helperText, isNotNull);
    await tester.enterText(find.byType(TextField).first, 'free');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField).first)
        .decoration?.helperText, isNull);
  });
}
