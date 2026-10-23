// §676 — тайл route.final («Default traffic (no rule matched)») живёт в
// хвосте вкладки Rules, вне ReorderableListView; на Directions его нет.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/routing_screen/routing_screen_helpers.dart';
import 'package:lxbox/screens/routing_screen/widgets/route_final_tile.dart';
import 'package:lxbox/screens/routing_screen/widgets/routing_tabs.dart';

const _title = 'Default traffic (no rule matched)';

const _options = [
  RoutingOutboundOption(label: 'direct', tag: 'direct-out'),
  RoutingOutboundOption(label: 'VPN 1', tag: 'vpn-1'),
  RoutingOutboundOption(label: 'block', tag: 'block', danger: true),
];

Widget _rulesTab({
  required List<String> rules,
  required String routeFinal,
  required ValueChanged<String> onFinal,
  ReorderCallback? onReorder,
}) {
  return MaterialApp(
    home: Scaffold(
      body: RoutingRulesTab(
        bottomPad: 0,
        itemCount: rules.length,
        onReorder: onReorder ?? (_, _) {},
        itemKey: (i) => ValueKey(rules[i]),
        itemBuilder: (i) => ListTile(
          title: Text(rules[i]),
          trailing: ReorderableDragStartListener(
            index: i,
            child: const Icon(Icons.drag_handle),
          ),
        ),
        onAdd: () {},
        routeFinalTile: RouteFinalTile(
          options: _options,
          routeFinal: routeFinal,
          onChanged: onFinal,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('Rules: тайл route.final последним, вне ReorderableListView, '
      'выбор отдаёт тег наружу', (tester) async {
    String? picked;
    await tester.pumpWidget(_rulesTab(
      rules: const ['rule A', 'rule B'],
      routeFinal: 'vpn-1',
      onFinal: (v) => picked = v,
    ));

    final tile = find.widgetWithText(ListTile, _title);
    expect(tile, findsOneWidget);
    // Вне перетаскиваемого списка.
    expect(
      find.descendant(
        of: find.byType(ReorderableListView),
        matching: find.text(_title),
      ),
      findsNothing,
    );
    // Последний элемент вкладки: ниже правил и кнопки «Add rule».
    final listChildren =
        tester.widget<ListView>(find.byType(ListView).first).childrenDelegate
            as SliverChildListDelegate;
    expect(listChildren.children.last, isA<RouteFinalTile>());
    expect(
      tester.getTopLeft(tile).dy,
      greaterThan(tester.getTopLeft(find.text('Add rule')).dy),
    );

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('block').last);
    await tester.pumpAndSettle();
    expect(picked, 'block');
  });

  testWidgets('Rules: перестановка правил не трогает тайл route.final',
      (tester) async {
    final rules = ['rule A', 'rule B'];
    var reorders = 0;
    await tester.pumpWidget(_rulesTab(
      rules: rules,
      routeFinal: 'direct-out',
      onFinal: (_) {},
      onReorder: (_, _) => reorders++,
    ));

    // Индексы ReorderableListView покрывают только правила.
    final rl = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    expect(
      find.descendant(
        of: find.byWidget(rl),
        matching: find.byType(RouteFinalTile),
      ),
      findsNothing,
    );

    final handle = find.byIcon(Icons.drag_handle).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(reorders, 1);
    expect(find.widgetWithText(ListTile, _title), findsOneWidget);
    final listChildren =
        tester.widget<ListView>(find.byType(ListView).first).childrenDelegate
            as SliverChildListDelegate;
    expect(listChildren.children.last, isA<RouteFinalTile>());
  });

  testWidgets('Directions: тайла route.final нет', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RoutingDirectionsTab(
          bottomPad: 0,
          directionCount: 1,
          onReorder: (_, _) {},
          onReorderStart: (_) {},
          onReorderEnd: (_) {},
          itemKey: (i) => ValueKey('d$i'),
          itemBuilder: (_) => const ListTile(title: Text('VPN 1')),
          onAddDirection: () {},
        ),
      ),
    ));
    expect(find.byType(RouteFinalTile), findsNothing);
    expect(find.textContaining('Default traffic'), findsNothing);
  });
}
