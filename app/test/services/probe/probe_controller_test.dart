import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/probe/probe_controller.dart';
import 'package:lxbox/services/probe/probe_runner.dart';

/// §296 — чистые decision-хелперы ProbeController (общие для folder/subs/user).
void main() {
  ProbeResult ok(int ms) => ProbeResult(ProbeStatus.ok, delayMs: ms);
  const failed = ProbeResult(ProbeStatus.failed);
  const broken = ProbeResult(ProbeStatus.broken);
  const pending = ProbeResult(ProbeStatus.pending);

  group('unreachableIndexes', () {
    test('failed/broken/invalid → в наборе; ok/pending → нет', () {
      final probe = {
        0: ok(100),
        1: failed,
        2: broken,
        3: const ProbeResult(ProbeStatus.invalid),
        4: pending,
      };
      expect(ProbeController.unreachableIndexes(probe), {1, 2, 3});
    });
    test('пусто → пустой набор', () {
      expect(ProbeController.unreachableIndexes({}), isEmpty);
    });
  });

  group('slowerThan', () {
    test('только ok медленнее порога', () {
      final probe = {0: ok(100), 1: ok(500), 2: ok(300), 3: failed};
      expect(ProbeController.slowerThan(probe, 250), {1, 2});
    });
    test('failed НЕ попадает (не ok)', () {
      expect(ProbeController.slowerThan({0: failed}, 0), isEmpty);
    });
  });

  group('pingSortOrder', () {
    test('ok по возрастанию delay, err в конец, stable tie-break', () {
      final probe = {0: ok(300), 1: failed, 2: ok(100), 3: pending};
      // ok: idx2(100) < idx0(300); pending idx3; failed idx1 в конец.
      expect(ProbeController.pingSortOrder(probe, 4), [2, 0, 3, 1]);
    });
    test('нетестированные (нет в map) — как pending, перед err', () {
      final probe = {0: failed, 1: ok(50)};
      // idx1(ok) → idx2(нетестирован=pending) → idx0(failed).
      expect(ProbeController.pingSortOrder(probe, 3), [1, 2, 0]);
    });
    test('стабильность: равный ранг → по исходному индексу', () {
      final probe = {0: ok(100), 1: ok(100)};
      expect(ProbeController.pingSortOrder(probe, 2), [0, 1]);
    });
  });

  group('remapAfterReorder', () {
    test('результаты переезжают на новые позиции', () {
      final probe = {0: ok(300), 1: ok(100)};
      // order[newI]=oldI: [1,0] → newIndex0 берёт old1, newIndex1 берёт old0.
      final remapped = ProbeController.remapAfterReorder(probe, [1, 0]);
      expect(remapped[0]!.delayMs, 100);
      expect(remapped[1]!.delayMs, 300);
    });
    test('отсутствующий old-результат не создаёт запись', () {
      final remapped = ProbeController.remapAfterReorder({0: ok(50)}, [1, 0]);
      expect(remapped.containsKey(0), isFalse); // old1 нет
      expect(remapped[1]!.delayMs, 50); // old0 → new1
    });
  });

  group('probeNodesOf', () {
    test('папка → члены (nullable, unfiltered — сохраняет disabled+broken)', () {
      final folder = FolderServers(
        id: 'f', name: 'F', enabled: true, tagPrefix: 'p:',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(raw: 'vless://u@h:443?type=ws&security=tls#A'),
          FolderMember(raw: 'garbage'), // node == null
        ],
      );
      final nodes = ProbeController.probeNodesOf(folder);
      expect(nodes.length, 2); // оба слота сохранены
      expect(nodes[1], isNull); // битый = null (вердикт broken по индексу)
    });
    test('подписка → базовый nodes[]', () {
      final sub = SubscriptionServers(
        id: 's', name: 'S', enabled: true, tagPrefix: 'p:',
        detourPolicy: DetourPolicy.defaults, url: 'https://x',
        nodes: <NodeSpec>[],
      );
      expect(ProbeController.probeNodesOf(sub), sub.nodes);
    });
  });
}
