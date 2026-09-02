import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
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
  const groupNode = ProbeResult(ProbeStatus.group);

  group('unreachableIndexes', () {
    test('failed/broken/invalid → в наборе; ok/pending/group → нет', () {
      final probe = {
        0: ok(100),
        1: failed,
        2: broken,
        3: const ProbeResult(ProbeStatus.invalid),
        4: pending,
        // §336 — автоузел не тестируется; «Disable unreachable» его не трогает.
        5: groupNode,
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
    test('§336: group — корзина «не тестировалась» (с pending), перед err', () {
      final probe = {0: failed, 1: groupNode, 2: ok(50), 3: pending};
      // ok idx2 → нетестированные idx1(group), idx3(pending) → failed idx0.
      expect(ProbeController.pingSortOrder(probe, 4), [2, 1, 3, 0]);
    });
  });

  // §339 — те же identity-ключи от списка нод (подписка/сервер).
  group('probeKeysForNodes', () {
    NodeSpec? node(String raw) => FolderMember(raw: raw).node;
    const uriA = 'vless://u1@h1.example:443?type=ws&security=tls#Alpha';
    const uriB = 'vless://u2@h2.example:443?type=ws&security=tls#Beta';

    test('§400 ключ = идентичность (тег); тёзку разводит `-2`, null → slot',
        () {
      // uriA и uriB — разные имена, третий узел тёзка первого («Alpha»).
      // Суффикс ставит УНИКАЛИЗАЦИЯ идентичности (`-2`), а не `_dedupKeys`
      // (`#2`): до дедупа дело не доходит, ключи уже разошлись.
      final keys = ProbeController.probeKeysForNodes(
          [node(uriA), node(uriB), node(uriA), null]);
      expect(keys, ['Alpha', 'Beta', 'Alpha-2', 'slot:3']);
      expect(keys.toSet(), hasLength(4)); // все уникальны
    });

    test('§400 узел БЕЗ идентичности падает на позиционный slot', () {
      // Группа идентичности не имеет (§2.3). Ключ ей всё равно нужен —
      // слот под вердикт занимает каждый член.
      final keys = ProbeController.probeKeysForNodes([
        AutoSelectSpec(
          id: 'g1',
          tag: 'Auto',
          label: 'Auto',
          membership: const RuleMembers(include: '.'),
        ),
        node(uriA),
      ]);
      expect(keys, ['slot:0', 'Alpha']);
    });

    test('ключ — функция идентичности: re-parse даёт тот же ключ', () {
      final k1 = ProbeController.probeKeysForNodes([node(uriA)]);
      final k2 = ProbeController.probeKeysForNodes([node(uriA)]);
      expect(k1, k2);
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

    test('§400 ПЕРЕИМЕНОВАНИЕ ключ МЕНЯЕТ — это смена идентичности', () {
      // Инверсия прежнего поведения. Ключ — имя узла: провайдер переименовал
      // узел, значит для нас это другой узел, и замер к нему не относится.
      final keys = ProbeController.probeKeys([m(a), m('${a}renamed')]);
      expect(keys, ['A', 'Arenamed']);
    });

    test('§400 правка АДРЕСА ключ не меняет — имя то же', () {
      // Обратная сторона: ротация сервера под тем же именем оставляет замер
      // при узле. Тёзкой второй узел здесь не становится — это отдельный
      // прогон, счётчик свой.
      expect(ProbeController.probeKeys([m(a)]),
          ProbeController.probeKeys([m('vless://u@h9:443?type=ws&security=tls#A')]));
    });

    test('дубли одного узла ячейку не делят: X, X-2, X-3', () {
      // Суффикс теперь от уникализации идентичности (§400 §2.2), а не от
      // `_dedupKeys` — форма другая (`-2`, не `#2`), смысл тот же: замеры
      // трёх строк не сваливаются в одну ячейку.
      final keys = ProbeController.probeKeys([m(a), m(a), m(a)]);
      expect(keys, ['A', 'A-2', 'A-3']);
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
