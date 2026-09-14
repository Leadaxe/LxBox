import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/screens/routing_screen/widgets/custom_rule_tile.dart';

/// §435 — параметры `CustomRuleTile` для строки правила узла: пометка
/// происхождения, подсказка приглушения, живой тумблер без меню и редактора.
void main() {
  Widget host(Widget tile) => MaterialApp(
        home: Scaffold(
          body: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: 1,
            onReorderItem: (_, _) {},
            itemBuilder: (ctx, i) => KeyedSubtree(key: const ValueKey('t'), child: tile),
          ),
        ),
      );

  CustomRuleTile nodeTile({
    required ValueChanged<bool> onSwitch,
    required ValueChanged<Offset> onLongPress,
    bool dimmed = false,
  }) =>
      CustomRuleTile(
        index: 0,
        rule: CustomRuleInline(name: 'home network', ipCidrs: const ['100.64.0.0/10']),
        displayName: 'home network',
        options: const [],
        subtitle: '1 cidrs → home',
        pickerValue: '',
        pickerDisabled: false,
        showOutbound: false,
        canDelete: false,
        originLabel: 'from node home',
        dimmed: dimmed,
        statusButton: null,
        onTap: null,
        onLongPressStart: onLongPress,
        onSwitchChanged: onSwitch,
        onOutboundChanged: (_) {},
      );

  testWidgets('пометка происхождения видна; подсказки о выключенном узле нет',
      (tester) async {
    await tester.pumpWidget(host(nodeTile(onSwitch: (_) {}, onLongPress: (_) {})));

    expect(find.text('from node home'), findsOneWidget);
    expect(find.text('1 cidrs → home'), findsOneWidget);
    expect(find.text('node is disabled'), findsNothing);
    // Приглушения нет: над строкой нет своего Opacity (у списка свои).
    expect(
      find.ancestor(of: find.text('home network'), matching: find.byType(Opacity)),
      findsNothing,
    );
  });

  testWidgets('dimmed: подсказка «node is disabled», строка приглушена, тумблер живой',
      (tester) async {
    bool? toggled;
    await tester.pumpWidget(
      host(nodeTile(onSwitch: (v) => toggled = v, onLongPress: (_) {}, dimmed: true)),
    );

    expect(find.text('node is disabled'), findsOneWidget);
    expect(
      find.ancestor(of: find.text('home network'), matching: find.byType(Opacity)),
      findsOneWidget,
    );

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(toggled, isFalse, reason: 'правило включено → тумблер выключает');
  });

  testWidgets('canDelete: false — long-press меню не вызывается', (tester) async {
    var longPressed = false;
    await tester.pumpWidget(
      host(nodeTile(onSwitch: (_) {}, onLongPress: (_) => longPressed = true)),
    );

    await tester.longPress(find.text('home network'));
    await tester.pump();
    expect(longPressed, isFalse);
  });
}
