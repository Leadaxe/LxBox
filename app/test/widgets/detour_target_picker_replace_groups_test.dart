import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_replace.dart';
import 'package:lxbox/widgets/detour_target_picker.dart';

/// Задача 756 — группа свёртки источника («Replace with a group») —
/// цель detour: пикер показывает её секцией Replace groups во всех режимах.
///
/// Mutation, под которую тест обязан упасть: секция Replace groups убрана
/// из `showDetourTargetPicker` либо из `visibleReplaceGroups` снят один из
/// фильтров (свой источник, выключенный источник, тёзка Направления).
SubscriptionServers _sub(String id, String tag, ReplaceMode mode,
        {bool enabled = true}) =>
    SubscriptionServers(
      id: id,
      name: 'Sub $id',
      url: 'https://example.com/$id',
      enabled: enabled,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      replace: SourceReplace(mode: mode, tag: tag),
    );

void main() {
  final entries = [
    SubscriptionEntry(list: _sub('s-manual', 'GroupManual', ReplaceMode.manual)),
    SubscriptionEntry(list: _sub('s-auto', 'GroupAuto', ReplaceMode.auto)),
    SubscriptionEntry(list: _sub('s-both', 'GroupBoth', ReplaceMode.both)),
    SubscriptionEntry(list: _sub('s-self', 'GroupSelf', ReplaceMode.manual)),
    SubscriptionEntry(
        list: _sub('s-off', 'GroupOff', ReplaceMode.manual, enabled: false)),
    SubscriptionEntry(list: _sub('s-clash', 'vpn-2', ReplaceMode.manual)),
  ];
  final directions = [
    Direction.fromJson({'tag': 'vpn-2', 'label': 'Second'}),
  ];

  test('visibleReplaceGroups: все режимы, без своего, выключенного и тёзки',
      () {
    final groups = visibleReplaceGroups(entries,
        directions: directions, selfSourceId: 's-self');
    expect([for (final g in groups) g.tag],
        ['GroupManual', 'GroupAuto', 'GroupBoth']);
  });

  testWidgets('секция Replace groups: выбор даёт корневую ссылку на имя группы',
      (tester) async {
    final controller = SubscriptionController();
    controller.debugSetEntries(entries);

    DetourTarget? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showDetourTargetPicker(
                context,
                controller: controller,
                directions: directions,
                selfSourceId: 's-self',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Replace groups'), findsOneWidget);
    expect(find.text('GroupManual'), findsOneWidget);
    expect(find.text('GroupAuto'), findsOneWidget);
    expect(find.text('GroupBoth'), findsOneWidget);
    expect(find.text('GroupSelf'), findsNothing);
    expect(find.text('GroupOff'), findsNothing);
    expect(find.text('vpn-2'), findsNothing);

    await tester.tap(find.text('GroupManual'));
    await tester.pumpAndSettle();
    expect(result?.link, const NodeLink(tag: 'GroupManual'));
  });
}
