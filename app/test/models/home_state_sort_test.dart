import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/home_state.dart';

/// §070 + §071 — sort options + manual mode tests.
/// Covers: pin direct/auto toggles, manual order application, new nodes
/// to end, cycle exit-from-manual semantics (next).
void main() {
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

  group('HomeState.sortedNodes — pin toggles (§070)', () {
    test('pinDirect ON + latencyAsc: direct-out первый', () {
      final s = HomeState(
        nodes: ['x', 'direct-out', 'y'],
        lastDelay: {'x': 50, 'y': 30},
        sortMode: NodeSortMode.latencyAsc,
      );
      expect(s.sortedNodes.first, 'direct-out');
    });

    test('pinDirect OFF + latencyAsc: direct-out по latency', () {
      // direct-out не имеет lastDelay → null → попадает в конец.
      final s = HomeState(
        nodes: ['x', 'direct-out', 'y'],
        lastDelay: {'x': 50, 'y': 30, 'direct-out': 10},
        sortMode: NodeSortMode.latencyAsc,
        pinDirect: false,
      );
      // direct-out с delay=10 — самый быстрый.
      expect(s.sortedNodes.first, 'direct-out');
      // Но это потому что fastest, не pinned. Проверим что pinAuto тоже отключён
      // и order = чисто по latency:
      expect(s.sortedNodes, ['direct-out', 'y', 'x']);
    });

    test('pinAuto OFF + nameAsc: ✨auto сортируется по имени', () {
      final s = HomeState(
        nodes: ['z', kAutoOutboundTag, 'a'],
        sortMode: NodeSortMode.nameAsc,
        pinAuto: false,
      );
      // ✨ (U+2728) codepoint > 'z' (0x7A) → ✨auto идёт в конец lowercase
      // сортировки. Главное проверяемое: НЕ первый (pinAuto OFF работает).
      expect(s.sortedNodes, ['a', 'z', kAutoOutboundTag]);
      expect(s.sortedNodes.first, isNot(kAutoOutboundTag));
    });

    test('default mode + pin ON: pinned сверху, rest в pristine order', () {
      final s = HomeState(
        nodes: ['x', 'direct-out', 'y', kAutoOutboundTag],
        sortMode: NodeSortMode.defaultOrder,
        // pinDirect/pinAuto defaults = true
      );
      // direct-out + ✨auto сверху в pinnedOrder, x/y в pristine config order.
      expect(s.sortedNodes, ['direct-out', kAutoOutboundTag, 'x', 'y']);
    });

    test('default mode + pin OFF: чистый pristine config order', () {
      final s = HomeState(
        nodes: ['x', 'direct-out', 'y', kAutoOutboundTag],
        sortMode: NodeSortMode.defaultOrder,
        pinDirect: false,
        pinAuto: false,
      );
      expect(s.sortedNodes, ['x', 'direct-out', 'y', kAutoOutboundTag]);
    });
  });

  group('HomeState.sortedNodes — manual mode (§071)', () {
    test('manualOrder применяется к non-pinned', () {
      final s = HomeState(
        nodes: ['direct-out', 'x', 'y', 'z'],
        sortMode: NodeSortMode.manual,
        manualOrder: ['z', 'x', 'y'],
      );
      expect(s.sortedNodes, ['direct-out', 'z', 'x', 'y']);
    });

    test('новая нода (не в manualOrder) → конец', () {
      final s = HomeState(
        nodes: ['x', 'y', 'newNode', 'z'],
        sortMode: NodeSortMode.manual,
        manualOrder: ['z', 'x', 'y'],
      );
      expect(s.sortedNodes, ['z', 'x', 'y', 'newNode']);
    });

    test('удалённая нода из manualOrder автоматически отфильтрована', () {
      final s = HomeState(
        nodes: ['x', 'z'],  // 'y' пропала
        sortMode: NodeSortMode.manual,
        manualOrder: ['z', 'x', 'y'],
      );
      expect(s.sortedNodes, ['z', 'x']);
    });

    test('manualOrder пустой + manual mode → fallback на pristine nodes', () {
      final s = HomeState(
        nodes: ['a', 'b', 'c'],
        sortMode: NodeSortMode.manual,
        manualOrder: const [],
      );
      // pinDirect/pinAuto = true defaults, но в nodes их нет → no pinned.
      expect(s.sortedNodes, ['a', 'b', 'c']);
    });

    test('manual mode + pinDirect ON: direct остаётся сверху', () {
      final s = HomeState(
        nodes: ['x', 'direct-out', 'y'],
        sortMode: NodeSortMode.manual,
        manualOrder: ['y', 'x'],
        pinDirect: true,
      );
      expect(s.sortedNodes, ['direct-out', 'y', 'x']);
    });

    test('manual mode + pinDirect OFF: direct в manualOrder', () {
      final s = HomeState(
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
