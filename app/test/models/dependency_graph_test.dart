import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/dependency_graph.dart';

/// §355 — граф detour-зависимостей: health-правила и BFS-распространение.
void main() {
  /// Мини-конфиг инцидента 02.08.2026: dns `yandex_udp` → detour vpn-2
  /// (selector), в vpn-2 выбирается «RU»; плюс нода `chained` с прямым
  /// detour на «RU» и второй канал vpn-9 поверх `chained` с dns `doh2`.
  String config({List<String> vpn2Members = const ['RU', 'DE']}) =>
      jsonEncode({
        'outbounds': [
          {'type': 'vless', 'tag': 'RU', 'server': '1.2.3.4'},
          {'type': 'vless', 'tag': 'DE', 'server': '5.6.7.8'},
          {'type': 'vless', 'tag': 'chained', 'detour': 'RU'},
          {'type': 'selector', 'tag': 'vpn-2', 'outbounds': vpn2Members},
          {
            'type': 'selector',
            'tag': 'vpn-9',
            'outbounds': ['chained', 'DE'],
          },
          {
            'type': 'urltest',
            'tag': 'auto-1',
            'outbounds': ['RU', 'DE'],
          },
        ],
        'endpoints': [
          {'type': 'wireguard', 'tag': 'wg-ep', 'detour': 'vpn-2'},
        ],
        'dns': {
          'servers': [
            {'type': 'udp', 'tag': 'yandex_udp', 'detour': 'vpn-2'},
            {'type': 'https', 'tag': 'doh2', 'detour': 'vpn-9'},
            {'type': 'udp', 'tag': 'plain', 'server': '8.8.8.8'},
          ],
        },
      });

  Map<String, Map<String, int>> delays(Map<String, int> flat) =>
      {'vpn-1': flat};

  test('репро инцидента: dead-нода, выбранная каналом, заражает dns и ноды',
      () {
    final g = DependencyGraph.fromConfig(config());
    final sick = g.computeSick(
      selections: {'vpn-2': 'RU'},
      delays: delays({'RU': -1}),
    );
    expect(sick.keys, ['RU']);
    final tags = {for (final d in sick['RU']!) d.tag: d};
    // Прямой detour на корень — via null.
    expect(tags['chained']!.via, isNull);
    expect(tags['chained']!.kind, 'node');
    // Через канал vpn-2 — via=vpn-2.
    expect(tags['yandex_udp']!.via, 'vpn-2');
    expect(tags['yandex_udp']!.isDns, isTrue);
    expect(tags['wg-ep']!.via, 'vpn-2');
    // chained болен → vpn-9 (selected=chained не задан) — doh2 НЕ заражён
    // без выбора chained в vpn-9.
    expect(tags.containsKey('doh2'), isFalse);
  });

  test('двухступенчатая цепочка: нода → канал → нода → канал → dns', () {
    final g = DependencyGraph.fromConfig(config());
    final sick = g.computeSick(
      selections: {'vpn-2': 'RU', 'vpn-9': 'chained'},
      delays: delays({'RU': -1}),
    );
    final tags = {for (final d in sick['RU']!) d.tag: d};
    expect(tags['doh2']!.via, 'vpn-9');
  });

  test('живой замер в любом канале снимает dead (консервативное правило)', () {
    final g = DependencyGraph.fromConfig(config());
    final sick = g.computeSick(
      selections: {'vpn-2': 'RU'},
      delays: {
        'vpn-1': {'RU': -1},
        'vpn-4': {'RU': 150},
      },
    );
    expect(sick, isEmpty);
  });

  test('нода без замеров — unknown, не тревожим', () {
    final g = DependencyGraph.fromConfig(config());
    final sick = g.computeSick(
      selections: {'vpn-2': 'RU'},
      delays: delays({'DE': 100}),
    );
    expect(sick, isEmpty);
  });

  test('dead-нода без зависимых — не корень', () {
    final g = DependencyGraph.fromConfig(config());
    // DE мертва, но выбор vpn-2 — RU (жива, замера нет), на DE никто не
    // ссылается detour'ом.
    final sick = g.computeSick(
      selections: {'vpn-2': 'RU'},
      delays: delays({'DE': -1}),
    );
    expect(sick, isEmpty);
  });

  test('urltest-канал не болеет по выбору (самолечение §308)', () {
    final g = DependencyGraph.fromConfig(jsonEncode({
      'outbounds': [
        {'type': 'vless', 'tag': 'RU'},
        {'type': 'vless', 'tag': 'DE'},
        {
          'type': 'urltest',
          'tag': 'auto-x',
          'outbounds': ['RU', 'DE'],
        },
        {'type': 'vless', 'tag': 'onAuto', 'detour': 'auto-x'},
      ],
      'dns': {'servers': []},
    }));
    // Выбор auto-x=RU в selections подавать нельзя по контракту — но даже
    // если подали, selector-набора auto-x нет → выбор игнорируется.
    final sick = g.computeSick(
      selections: {'auto-x': 'RU'},
      delays: delays({'RU': -1}),
    );
    expect(sick, isEmpty);
  });

  test('urltest болен только при полностью мёртвом составе', () {
    final g = DependencyGraph.fromConfig(jsonEncode({
      'outbounds': [
        {'type': 'vless', 'tag': 'RU'},
        {'type': 'vless', 'tag': 'DE'},
        {
          'type': 'urltest',
          'tag': 'auto-x',
          'outbounds': ['RU', 'DE'],
        },
        {'type': 'vless', 'tag': 'onAuto', 'detour': 'auto-x'},
      ],
      'dns': {'servers': []},
    }));
    final sick = g.computeSick(
      selections: const {},
      delays: delays({'RU': -1, 'DE': -3}),
    );
    // Оба корня видят onAuto через мёртвый auto-x.
    expect(sick.keys, containsAll(['RU', 'DE']));
    expect(sick['RU']!.single.tag, 'onAuto');
    expect(sick['RU']!.single.via, 'auto-x');
  });

  test('смена выбора канала на живую ноду снимает болезнь', () {
    final g = DependencyGraph.fromConfig(config());
    final sick = g.computeSick(
      selections: {'vpn-2': 'DE'},
      delays: delays({'RU': -1, 'DE': 120}),
    );
    // RU мертва, но выбор канала — DE; зависимых через канал нет. Прямой
    // detour chained на RU остаётся — RU корень с одним пострадавшим.
    expect(sick.keys, ['RU']);
    expect(sick['RU']!.map((d) => d.tag), ['chained']);
  });

  test('malformed JSON → пустой граф', () {
    final g = DependencyGraph.fromConfig('{broken');
    expect(g.isEmpty, isTrue);
    expect(g.computeSick(selections: const {}, delays: const {}), isEmpty);
  });

  test('directDependents отдаёт прямых зависимых без динамики', () {
    final g = DependencyGraph.fromConfig(config());
    expect(
      g.directDependents('vpn-2').map((d) => d.tag).toSet(),
      {'yandex_udp', 'wg-ep'},
    );
    expect(g.directDependents('RU').single.tag, 'chained');
  });
}
