import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/screens/subscriptions_screen/widgets/chains_section.dart';

// §393 C7 — цепочки в списке источников. Не тест на вёрстку: проверяем, что
// секция появляется только при наличии цепочек и что тап/тумблер доходят до
// нужной записи.

Widget _host(List<SourceChain> chains,
        {void Function(SourceChain)? onTap,
        void Function(SourceChain)? onToggle}) =>
    MaterialApp(
      home: Scaffold(
        body: ChainsSection(
          chains: chains,
          onTap: onTap ?? (_) {},
          onToggle: onToggle ?? (_) {},
        ),
      ),
    );

void main() {
  testWidgets('без цепочек секции нет вовсе', (tester) async {
    await tester.pumpWidget(_host(const []));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('строка показывает имя и тег цепочки', (tester) async {
    await tester.pumpWidget(_host(const [
      SourceChain(tag: 'chain-1', label: 'Via Germany', hops: ['a', 'b']),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('Via Germany'), findsOneWidget);
    expect(find.textContaining('chain-1'), findsOneWidget);
  });

  testWidgets('без label показываем тег: имени цепочке не выдумываем',
      (tester) async {
    await tester.pumpWidget(_host(const [
      SourceChain(tag: 'chain-1', hops: ['a', 'b']),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('chain-1'), findsOneWidget);
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
