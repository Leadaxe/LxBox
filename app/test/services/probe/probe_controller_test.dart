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

  // §326 — ключ результата = идентичность узла, не позиция. `remapAfterReorder`
  // снят вместе с позиционным хранением (перепривязывать больше нечего).
  group('probeKeys', () {
    FolderMember m(String raw) => FolderMember(raw: raw);
    const a = 'vless://u@h1:443?type=ws&security=tls#A';
    const b = 'vless://u@h2:443?type=ws&security=tls#B';

    test('разные узлы → разные ключи', () {
      final keys = ProbeController.probeKeys([m(a), m(b)]);
      expect(keys[0], isNot(keys[1]));
    });

    test('ключ не зависит от позиции: удаление соседа не двигает остальные', () {
      final before = ProbeController.probeKeys([m(a), m(b)]);
      final after = ProbeController.probeKeys([m(b)]); // удалили первого
      expect(after.single, before[1]); // ключ B тот же — замер остался при нём
    });

    test('переименование (ремарка) ключ не меняет — это тот же сервер', () {
      final keys = ProbeController.probeKeys([m(a), m('$a-renamed')]);
      expect(keys[0], keys[1].split('#').first);
    });

    test('правка параметров узла ключ меняет — считаем другим сервером', () {
      final keys = ProbeController.probeKeys(
          [m(a), m('vless://u@h1:8443?type=ws&security=tls#A')]);
      expect(keys[0], isNot(keys[1]));
    });

    test('дубли одного сервера получают суффикс, а не делят ячейку', () {
      final keys = ProbeController.probeKeys([m(a), m(a), m(a)]);
      expect(keys.toSet().length, 3);
      expect(keys[1], '${keys[0]}#2');
      expect(keys[2], '${keys[0]}#3');
    });

    test('битый член (node == null) получает raw-ключ', () {
      final keys = ProbeController.probeKeys([m('garbage'), m('other junk')]);
      expect(keys[0], 'raw:garbage');
      expect(keys[1], 'raw:other junk');
    });

    test('длина всегда равна числу членов (слот на каждую строку)', () {
      expect(ProbeController.probeKeys([m(a), m('garbage'), m(a)]).length, 3);
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
