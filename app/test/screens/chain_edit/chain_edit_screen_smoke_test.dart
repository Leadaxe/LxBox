import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/config_node.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/screens/chain_edit_screen.dart';

// §393 C7 — экран цепочки строится и переживает взаимодействие. Не тест на
// вёрстку и не на тексты (AGENTS.md): проверяем, что форма поднимается, что
// блокирующая находка реально запирает сохранение и что порядок позиций
// меняется тем, чем нарисован.

ParsedConfig _config() => ParsedConfig.parse(jsonEncode({
      'outbounds': [
        {'tag': 'home', 'type': 'vless'},
        {'tag': 'de-exit', 'type': 'vless'},
        {
          'tag': 'de-reality',
          'type': 'vless',
          'tls': {
            'enabled': true,
            'reality': {'enabled': true},
          },
        },
      ],
    }));

Widget _host(SourceChain chain) => MaterialApp(
      home: ChainEditScreen(
        initial: chain,
        config: _config(),
        directions: const [Direction(tag: 'vpn-1', label: 'vpn-1')],
        chains: [chain],
      ),
    );

void main() {
  testWidgets('форма поднимается и показывает позиции', (tester) async {
    await tester.pumpWidget(_host(
        const SourceChain(tag: 'via-de', hops: ['home', 'de-exit'])));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(find.text('de-exit'), findsOneWidget);
  });

  testWidgets('одна позиция — кнопка сохранения заперта', (tester) async {
    await tester
        .pumpWidget(_host(const SourceChain(tag: 'via-de', hops: ['home'])));
    await tester.pumpAndSettle();
    final save = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.check));
    expect(save.onPressed, isNull);
  });

  testWidgets('две живые позиции — сохранение доступно', (tester) async {
    await tester.pumpWidget(_host(
        const SourceChain(tag: 'via-de', hops: ['home', 'de-exit'])));
    await tester.pumpAndSettle();
    final save = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.check));
    expect(save.onPressed, isNotNull);
  });

  testWidgets('стрелка вниз меняет порядок пакета', (tester) async {
    await tester.pumpWidget(_host(
        const SourceChain(tag: 'via-de', hops: ['home', 'de-exit'])));
    await tester.pumpAndSettle();
    // Первая активная «вниз» принадлежит позиции 1.
    await tester.tap(find.byIcon(Icons.arrow_downward).first);
    await tester.pumpAndSettle();
    // Порядок читаем по номерам-аватарам: позиция 1 теперь de-exit.
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    final titles = [
      for (final t in tiles)
        if (t.title is Text) (t.title as Text).data,
    ];
    expect(titles.indexOf('de-exit'), lessThan(titles.indexOf('home')));
  });

  testWidgets('снятый tls.utls на reality-звене запирает сохранение',
      (tester) async {
    await tester.pumpWidget(_host(const SourceChain(
      tag: 'via-de',
      hops: ['home', 'de-reality'],
      strip: {kChainStripTlsUtls: true},
    )));
    await tester.pumpAndSettle();
    final save = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.check));
    expect(save.onPressed, isNull);
  });

  testWidgets('пикер позиций открывается и не предлагает уже занятые',
      (tester) async {
    await tester
        .pumpWidget(_host(const SourceChain(tag: 'via-de', hops: ['home'])));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    // `home` уже стоит позицией — в пикере его быть не должно; в форме он
    // остался ровно один раз.
    expect(find.text('home'), findsOneWidget);
    expect(find.text('de-exit'), findsOneWidget);
  });

  testWidgets('Advanced раскрывается: idle_timeout и каталог strip на месте',
      (tester) async {
    await tester.pumpWidget(_host(
        const SourceChain(tag: 'via-de', hops: ['home', 'de-exit'])));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    // Каталог strip закрыт четырьмя ключами ядра — показываем ровно их.
    for (final key in kChainStripKeys) {
      expect(find.text(key), findsOneWidget);
    }
  });

  testWidgets('галка каталога трёхзначна: не тронута → null', (tester) async {
    await tester.pumpWidget(_host(
        const SourceChain(tag: 'via-de', hops: ['home', 'de-exit'])));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    final boxes = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .toList();
    expect(boxes, hasLength(kChainStripKeys.length));
    // Нетронутое состояние — именно null, а не false: «как у ядра» и «я так
    // решил» обязаны различаться уже в форме.
    expect(boxes.every((b) => b.value == null), isTrue);
  });

  testWidgets('свой тег среди тегов конфига конфликтом не считается',
      (tester) async {
    // Собранная цепочка сама лежит в конфиге узлом `type: chain` — принять
    // это за «имя занято» значило бы запереть форму у любой рабочей цепочки.
    await tester.pumpWidget(MaterialApp(
      home: ChainEditScreen(
        initial: const SourceChain(tag: 'via-de', hops: ['home', 'de-exit']),
        config: ParsedConfig.parse(jsonEncode({
          'outbounds': [
            {'tag': 'home', 'type': 'vless'},
            {'tag': 'de-exit', 'type': 'vless'},
            {
              'tag': 'via-de',
              'type': 'chain',
              'outbounds': ['home', 'de-exit'],
            },
          ],
        })),
        directions: const [Direction(tag: 'vpn-1', label: 'vpn-1')],
        chains: const [SourceChain(tag: 'via-de', hops: ['home', 'de-exit'])],
      ),
    ));
    await tester.pumpAndSettle();
    final save = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.check));
    expect(save.onPressed, isNotNull);
  });
}
