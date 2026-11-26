import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/config_node.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/screens/chain_edit_screen.dart';

import '../../contract_paths.dart';

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
          'server': '203.0.113.7',
          'server_port': 443,
          'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811',
          'tls': {
            'enabled': true,
            'server_name': 'example.com',
            'utls': {'enabled': true, 'fingerprint': 'chrome'},
            'reality': {
              'enabled': true,
              'public_key': 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0',
              'short_id': '0123abcd',
            },
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
  setUpAll(loadTestRegistry);

  testWidgets('форма поднимается и показывает позиции', (tester) async {
    await tester.pumpWidget(_host(
        const SourceChain(tag: 'via-de', hops: [NodeLink(tag: 'home'), NodeLink(tag: 'de-exit')])));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(find.text('de-exit'), findsOneWidget);
  });

  testWidgets('одна позиция — кнопка сохранения заперта', (tester) async {
    await tester
        .pumpWidget(_host(const SourceChain(tag: 'via-de', hops: [NodeLink(tag: 'home')])));
    await tester.pumpAndSettle();
    final save = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.check));
    expect(save.onPressed, isNull);
  });

  testWidgets('нельзя сохранить — «назад» даёт выйти без сохранения, без Save',
      (tester) async {
    const chain = SourceChain(
        tag: 'via-de', hops: [NodeLink(tag: 'home'), NodeLink(tag: 'de-exit')]);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => Navigator.push(
            ctx,
            MaterialPageRoute<void>(
              builder: (_) => ChainEditScreen(
                initial: chain,
                config: _config(),
                directions: const [Direction(tag: 'vpn-1', label: 'vpn-1')],
                chains: const [chain],
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Убрать вторую позицию: форма грязная и с блокирующей ошибкой.
    await tester.tap(find.byTooltip('Remove position').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Save'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(ChainEditScreen), findsNothing);
  });

  testWidgets('две живые позиции — сохранение доступно', (tester) async {
    await tester.pumpWidget(_host(
        const SourceChain(tag: 'via-de', hops: [NodeLink(tag: 'home'), NodeLink(tag: 'de-exit')])));
    await tester.pumpAndSettle();
    final save = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.check));
    expect(save.onPressed, isNotNull);
  });

  testWidgets('reorder-колбэк меняет порядок пакета', (tester) async {
    await tester.pumpWidget(_host(
        const SourceChain(tag: 'via-de', hops: [NodeLink(tag: 'home'), NodeLink(tag: 'de-exit')])));
    await tester.pumpAndSettle();
    // Логика порядка, не жест: дёргаем колбэк списка так же, как это сделал бы
    // drag позиции 1 на место позиции 2. onReorderItem уже нормализует
    // newIndex под удалённый элемент, поэтому «вниз на одну» это ровно 1.
    final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView));
    list.onReorderItem!(0, 1);
    await tester.pumpAndSettle();
    // Порядок читаем по номерам-аватарам: позиция 1 теперь de-exit.
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    final titles = [
      for (final t in tiles)
        if (t.title is Text) (t.title as Text).data,
    ];
    expect(titles.indexOf('de-exit'), lessThan(titles.indexOf('home')));
  });

  testWidgets('пикер позиций открывается и не предлагает уже занятые',
      (tester) async {
    await tester
        .pumpWidget(_host(const SourceChain(tag: 'via-de', hops: [NodeLink(tag: 'home')])));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    // `home` уже стоит позицией — в пикере его быть не должно; в форме он
    // остался ровно один раз.
    expect(find.text('home'), findsOneWidget);
    expect(find.text('de-exit'), findsOneWidget);
  });

  // §761 — блока Advanced нет: idle_timeout и strip ядро rc.2 не принимает.
  testWidgets('Advanced нет: ни idle_timeout, ни каталога strip', (tester) async {
    await tester.pumpWidget(_host(
        const SourceChain(tag: 'via-de', hops: [NodeLink(tag: 'home'), NodeLink(tag: 'de-exit')])));
    await tester.pumpAndSettle();
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('свой тег среди тегов конфига конфликтом не считается',
      (tester) async {
    // Собранная цепочка сама лежит в конфиге узлом `type: chain` — принять
    // это за «имя занято» значило бы запереть форму у любой рабочей цепочки.
    await tester.pumpWidget(MaterialApp(
      home: ChainEditScreen(
        initial: const SourceChain(tag: 'via-de', hops: [NodeLink(tag: 'home'), NodeLink(tag: 'de-exit')]),
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
        chains: const [SourceChain(tag: 'via-de', hops: [NodeLink(tag: 'home'), NodeLink(tag: 'de-exit')])],
      ),
    ));
    await tester.pumpAndSettle();
    final save = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.check));
    expect(save.onPressed, isNotNull);
  });
}
