import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/screens/subscriptions_screen/widgets/chains_section.dart';
import 'package:lxbox/widgets/reorder_grab_strip.dart';

// §393 D1 — цепочка СТРОКОЙ общего списка источников (директива оператора
// 24.08): отдельной секции «Цепочки хопов» больше нет, ряд тот же, что у
// подписки. Не тест на вёрстку: проверяем, что ряд несёт идентичность
// цепочки, тянется за drag-handle наравне со всеми и что тап/тумблер доходят
// до нужной записи.

Widget _host(List<SourceChain> chains,
        {void Function(SourceChain)? onTap,
        void Function(SourceChain)? onToggle}) =>
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            for (var i = 0; i < chains.length; i++)
              ChainEntryTile(
                chain: chains[i],
                dragIndex: i,
                onTap: () => onTap?.call(chains[i]),
                onToggle: () => onToggle?.call(chains[i]),
              ),
          ],
        ),
      ),
    );

void main() {
  testWidgets('строка показывает тег цепочки — её единственное имя',
      (tester) async {
    await tester.pumpWidget(_host(const [
      SourceChain(tag: 'chain-1', hops: ['a', 'b']),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('chain-1'), findsOneWidget);
  });

  testWidgets('у ряда есть grab-strip: цепочка перетаскивается наравне со всеми',
      (tester) async {
    await tester.pumpWidget(_host(const [
      SourceChain(tag: 'chain-1', hops: ['a', 'b']),
    ]));
    await tester.pumpAndSettle();
    expect(find.byType(ReorderGrabStrip), findsOneWidget);
  });

  testWidgets('тап уходит в нужную цепочку', (tester) async {
    SourceChain? tapped;
    await tester.pumpWidget(_host(
      const [
        SourceChain(tag: 'chain-1', hops: ['a', 'b']),
        SourceChain(tag: 'chain-2', hops: ['c', 'd']),
      ],
      onTap: (c) => tapped = c,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('chain-2'));
    await tester.pumpAndSettle();
    expect(tapped?.tag, 'chain-2');
  });

  testWidgets('тумблер уходит в нужную цепочку', (tester) async {
    SourceChain? toggled;
    await tester.pumpWidget(_host(
      const [
        SourceChain(tag: 'chain-1', hops: ['a', 'b']),
        SourceChain(tag: 'chain-2', hops: ['c', 'd'], enabled: false),
      ],
      onToggle: (c) => toggled = c,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();
    expect(toggled?.tag, 'chain-2');
  });
}
