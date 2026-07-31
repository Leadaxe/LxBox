import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/home_state.dart';

/// §070 + §071 + §125 — sort options + manual mode + pin-by-type.
/// Covers: pin direct/auto toggles (по ТИПУ из конфига — §125, не по тегу),
/// manual order application, new nodes to end, cycle exit-from-manual semantics.
void main() {
  // §125 — пин direct/auto определяется по outbound-type из конфига. Хелпер
  // строит configRaw, где перечисленные теги получают заданный type (прочие —
  // дефолтный 'vless', т.е. обычные прокси-ноды).
  String cfg(List<String> tags, {Map<String, String> types = const {}}) {
    return jsonEncode({
      'outbounds': [
        for (final t in tags) {'tag': t, 'type': types[t] ?? 'vless'},
      ],
    });
  }

  // §322 — auto-теги КАНАЛОВ: только им положен пин в верхнюю секцию
  // (у узла автовыбора подписки/папки тип тоже urltest, но он обычная нода).
  const chAuto = {'✨auto', 'vpn-1-auto', 'vpn-2-auto'};

  // Часто используемая раскладка: direct-out=direct, *-auto=urltest.
  String cfgDA(List<String> tags) => cfg(tags, types: {
        'direct-out': 'direct',
        '✨auto': 'urltest',
        'vpn-1-auto': 'urltest',
        'vpn-2-auto': 'urltest',
        'block': 'block',
      });

  group('NodeSortMode.next — §100 carousel (incl. manual)', () {
    test('default → latencyAsc', () {
      expect(NodeSortMode.defaultOrder.next, NodeSortMode.latencyAsc);
    });
    test('latencyAsc → nameAsc', () {
      expect(NodeSortMode.latencyAsc.next, NodeSortMode.nameAsc);
    });
    test('nameAsc → manual (§100 — Custom теперь в карусели)', () {
      expect(NodeSortMode.nameAsc.next, NodeSortMode.manual);
    });
    test('manual → defaultOrder (замыкает цикл)', () {
      expect(NodeSortMode.manual.next, NodeSortMode.defaultOrder);
    });
  });

  group('HomeState.sortedNodes — pin toggles (§070/§125 по типу)', () {
    test('pinDirect ON + latencyAsc: direct первый', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['x', 'direct-out', 'y']),
        nodes: ['x', 'direct-out', 'y'],
        lastDelay: {'x': 50, 'y': 30},
        sortMode: NodeSortMode.latencyAsc,
      );
      expect(s.sortedNodes.first, 'direct-out');
    });

    test('pinDirect OFF + latencyAsc: direct по latency', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['x', 'direct-out', 'y']),
        nodes: ['x', 'direct-out', 'y'],
        lastDelay: {'x': 50, 'y': 30, 'direct-out': 10},
        sortMode: NodeSortMode.latencyAsc,
        pinDirect: false,
      );
      // direct-out с delay=10 — самый быстрый, но не pinned.
      expect(s.sortedNodes, ['direct-out', 'y', 'x']);
    });

    test('§125 — auto-двойник vpn-1-auto пинится по типу urltest', () {
      // Имя НЕ '✨auto', но type==urltest → должен попасть в pinned (вверх).
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['z', 'vpn-1-auto', 'a']),
        nodes: ['z', 'vpn-1-auto', 'a'],
        sortMode: NodeSortMode.nameAsc,
        // pinAuto = true default
      );
      expect(s.sortedNodes.first, 'vpn-1-auto');
    });

    test('pinAuto OFF + nameAsc: auto-двойник сортируется по имени', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['z', 'vpn-1-auto', 'a']),
        nodes: ['z', 'vpn-1-auto', 'a'],
        sortMode: NodeSortMode.nameAsc,
        pinAuto: false,
      );
      // 'a' < 'vpn-1-auto' < 'z' lowercase → auto НЕ первый (pinAuto OFF).
      expect(s.sortedNodes, ['a', 'vpn-1-auto', 'z']);
      expect(s.sortedNodes.first, isNot('vpn-1-auto'));
    });

    test('default mode + pin ON: direct + auto сверху, rest pristine', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['x', 'direct-out', 'y', 'vpn-1-auto']),
        nodes: ['x', 'direct-out', 'y', 'vpn-1-auto'],
        sortMode: NodeSortMode.defaultOrder,
      );
      // direct первым, затем urltest-двойник, x/y в pristine config order.
      expect(s.sortedNodes, ['direct-out', 'vpn-1-auto', 'x', 'y']);
    });

    test('default mode + pin OFF: чистый pristine config order', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['x', 'direct-out', 'y', 'vpn-1-auto']),
        nodes: ['x', 'direct-out', 'y', 'vpn-1-auto'],
        sortMode: NodeSortMode.defaultOrder,
        pinDirect: false,
        pinAuto: false,
      );
      expect(s.sortedNodes, ['x', 'direct-out', 'y', 'vpn-1-auto']);
    });

    test('несколько auto-двойников: все пинятся, direct первым', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['x', 'vpn-2-auto', 'direct-out', 'vpn-1-auto', 'y']),
        nodes: ['x', 'vpn-2-auto', 'direct-out', 'vpn-1-auto', 'y'],
        sortMode: NodeSortMode.defaultOrder,
      );
      // direct сверху, затем оба urltest в config-порядке, потом x/y.
      expect(s.sortedNodes,
          ['direct-out', 'vpn-2-auto', 'vpn-1-auto', 'x', 'y']);
    });
  });

  group('§196 — активная нода пинится после direct/auto', () {
    test('активная нода сразу после direct+auto при latencyAsc', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['x', 'direct-out', 'y', 'vpn-1-auto', 'z']),
        nodes: ['x', 'direct-out', 'y', 'vpn-1-auto', 'z'],
        lastDelay: {'x': 10, 'y': 20, 'z': 30}, // z самый медленный
        activeInGroup: 'z',
        sortMode: NodeSortMode.latencyAsc,
      );
      // direct → auto → активная (z), затем rest по latency (x<y).
      expect(s.sortedNodes, ['direct-out', 'vpn-1-auto', 'z', 'x', 'y']);
    });

    test('активная при любой сортировке — nameAsc', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['a', 'direct-out', 'b', 'z']),
        nodes: ['a', 'direct-out', 'b', 'z'],
        activeInGroup: 'z', // лексикографически последняя
        sortMode: NodeSortMode.nameAsc,
      );
      // direct → активная(z) → rest по имени (a, b).
      expect(s.sortedNodes, ['direct-out', 'z', 'a', 'b']);
    });

    test('активная при default order', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['x', 'y', 'z']),
        nodes: ['x', 'y', 'z'],
        activeInGroup: 'y',
        sortMode: NodeSortMode.defaultOrder,
      );
      expect(s.sortedNodes, ['y', 'x', 'z']); // y вверх, x/z pristine
    });

    test('активная нода = direct/auto → НЕ дублируется', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['x', 'direct-out', 'vpn-1-auto']),
        nodes: ['x', 'direct-out', 'vpn-1-auto'],
        activeInGroup: 'vpn-1-auto', // уже в pinned (urltest)
        sortMode: NodeSortMode.latencyAsc,
      );
      // vpn-1-auto не должен повториться.
      expect(s.sortedNodes, ['direct-out', 'vpn-1-auto', 'x']);
      expect(s.sortedNodes.where((n) => n == 'vpn-1-auto').length, 1);
    });

    test('нет активной → старое поведение', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['x', 'direct-out', 'y']),
        nodes: ['x', 'direct-out', 'y'],
        sortMode: NodeSortMode.latencyAsc,
        lastDelay: {'x': 20, 'y': 10},
      );
      expect(s.sortedNodes, ['direct-out', 'y', 'x']);
    });

    test('pinnedNodeCount = direct + auto + активная', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['x', 'direct-out', 'vpn-1-auto', 'y']),
        nodes: ['x', 'direct-out', 'vpn-1-auto', 'y'],
        activeInGroup: 'x',
        sortMode: NodeSortMode.latencyAsc,
      );
      expect(s.pinnedNodeCount, 3); // direct + auto + x
      expect(s.sortedNodes.take(3), ['direct-out', 'vpn-1-auto', 'x']);
    });

    test('активная нода не в списке nodes → игнор', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['x', 'y']),
        nodes: ['x', 'y'],
        activeInGroup: 'ghost', // нет в nodes
        sortMode: NodeSortMode.nameAsc,
      );
      expect(s.sortedNodes, ['x', 'y']);
      expect(s.pinnedNodeCount, 0);
    });
  });

  group('§201 — block пинится сверху', () {
    test('block после direct/auto, перед rest', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['x', 'direct-out', 'block', 'vpn-1-auto', 'y']),
        nodes: ['x', 'direct-out', 'block', 'vpn-1-auto', 'y'],
        sortMode: NodeSortMode.defaultOrder,
      );
      // direct → urltest → block → rest (pristine x/y).
      expect(s.sortedNodes, ['direct-out', 'vpn-1-auto', 'block', 'x', 'y']);
    });

    test('block пинится при любой сортировке', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['z', 'block', 'a']),
        nodes: ['z', 'block', 'a'],
        sortMode: NodeSortMode.nameAsc,
      );
      // block сверху, rest по имени (a, z).
      expect(s.sortedNodes, ['block', 'a', 'z']);
    });
  });

  group('HomeState.sortedNodes — manual mode (§071)', () {
    test('manualOrder применяется к non-pinned', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['direct-out', 'x', 'y', 'z']),
        nodes: ['direct-out', 'x', 'y', 'z'],
        sortMode: NodeSortMode.manual,
        manualOrder: ['z', 'x', 'y'],
      );
      expect(s.sortedNodes, ['direct-out', 'z', 'x', 'y']);
    });

    test('новая нода (не в manualOrder) → конец', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfg(['x', 'y', 'newNode', 'z']),
        nodes: ['x', 'y', 'newNode', 'z'],
        sortMode: NodeSortMode.manual,
        manualOrder: ['z', 'x', 'y'],
      );
      expect(s.sortedNodes, ['z', 'x', 'y', 'newNode']);
    });

    test('удалённая нода из manualOrder автоматически отфильтрована', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfg(['x', 'z']),
        nodes: ['x', 'z'],
        sortMode: NodeSortMode.manual,
        manualOrder: ['z', 'x', 'y'],
      );
      expect(s.sortedNodes, ['z', 'x']);
    });

    test('manualOrder пустой + manual mode → fallback на pristine nodes', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfg(['a', 'b', 'c']),
        nodes: ['a', 'b', 'c'],
        sortMode: NodeSortMode.manual,
        manualOrder: const [],
      );
      // нет direct/urltest → no pinned.
      expect(s.sortedNodes, ['a', 'b', 'c']);
    });

    test('manual mode + pinDirect ON: direct остаётся сверху', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['x', 'direct-out', 'y']),
        nodes: ['x', 'direct-out', 'y'],
        sortMode: NodeSortMode.manual,
        manualOrder: ['y', 'x'],
        pinDirect: true,
      );
      expect(s.sortedNodes, ['direct-out', 'y', 'x']);
    });

    test('manual mode + pinDirect OFF: direct в manualOrder', () {
      final s = HomeState(
        channelAutoTags: chAuto,
        configRaw: cfgDA(['x', 'direct-out', 'y']),
        nodes: ['x', 'direct-out', 'y'],
        sortMode: NodeSortMode.manual,
        manualOrder: ['y', 'direct-out', 'x'],
        pinDirect: false,
      );
      expect(s.sortedNodes, ['y', 'direct-out', 'x']);
    });
  });

  group('HomeState.copyWith — new fields', () {
    test('default state: pinDirect=true, pinAuto=true, resort=true, gen=0', () {
      final s = HomeState();
      expect(s.pinDirect, true);
      expect(s.pinAuto, true);
      expect(s.resortOnManualPing, true);
      expect(s.pingBatchGen, 0);
      expect(s.manualOrder, isEmpty);
    });

    test('copyWith pinDirect=false — остальное intact', () {
      final s = HomeState();
      final s2 = s.copyWith(pinDirect: false);
      expect(s2.pinDirect, false);
      expect(s2.pinAuto, true);
      expect(s2.resortOnManualPing, true);
    });

    test('copyWith pingBatchGen bump — старое значение не реюзается', () {
      final s = HomeState(pingBatchGen: 5);
      final s2 = s.copyWith(pingBatchGen: 6);
      expect(s2.pingBatchGen, 6);
    });

    test('copyWith manualOrder — новый list', () {
      final s = HomeState();
      final s2 = s.copyWith(manualOrder: const ['a', 'b']);
      expect(s2.manualOrder, ['a', 'b']);
    });
  });
}
