import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/screens/stats_screen/routing_section.dart';
import 'package:lxbox/services/selector_info.dart';
import 'package:lxbox/services/traffic_profiler.dart';
import 'package:lxbox/vpn/cc_channel.dart';
import 'package:lxbox/widgets/detour_target_picker.dart';

/// §251 — схлопывание «селектор + его выбор» в `селектор (выбор)`:
/// pure-fold, обе routingLine-модели (TrafficEvent / CcConnection), строка
/// Detour общей Routing-секции, подпись Направления в пикере. Chain НЕ фолдится.
///
/// Реальный эталон с устройства (WARP-MASQUE через detour-Направление vpn-4):
///   outbound_chain = [WARP out, vpn-1]
///   detour_chain   = [vpn-4, 🇳🇱 Нидерланды, WARP in]
void main() {
  setUp(() => SelectorInfo.I.resetForTesting());
  tearDown(() => SelectorInfo.I.resetForTesting());

  group('foldSelectorPairs (pure)', () {
    test('пара «селектор + выбор» схлопывается', () {
      SelectorInfo.I.setFallbackTags(['vpn-4']);
      expect(
        foldSelectorPairs(['vpn-4', '🇳🇱 Нидерланды', 'WARP in']),
        ['vpn-4 (🇳🇱 Нидерланды)', 'WARP in'],
      );
    });

    test('две пары (двойное Направление в цепочке) — два схлопывания', () {
      SelectorInfo.I.setFallbackTags(['vpn-4', 'vpn-5']);
      expect(
        foldSelectorPairs(['vpn-4', 'A', 'vpn-5', 'B', 'WARP in']),
        ['vpn-4 (A)', 'vpn-5 (B)', 'WARP in'],
      );
    });

    test('селектор последним элементом — без следующего не фолдится', () {
      SelectorInfo.I.setFallbackTags(['vpn-4']);
      expect(foldSelectorPairs(['WARP in', 'vpn-4']), ['WARP in', 'vpn-4']);
    });

    test('без известных селекторов — список как есть', () {
      expect(
        foldSelectorPairs(['vpn-4', '🇳🇱', 'WARP in']),
        ['vpn-4', '🇳🇱', 'WARP in'],
      );
    });

    test('пустой и одиночный — без изменений', () {
      SelectorInfo.I.setFallbackTags(['vpn-4']);
      expect(foldSelectorPairs([]), isEmpty);
      expect(foldSelectorPairs(['vpn-4']), ['vpn-4']);
    });

    test('Направление в AUTO: серия селекторов вкладывается, узел не теряется', () {
      // Ядро для Направления в режиме AUTO отдаёт [Направление, его двойник, узел, …]
      // (SPEC 017 — разворот вложенных групп в detour-хвосте).
      SelectorInfo.I.setFallbackTags(['vpn-4', 'vpn-4-auto']);
      expect(
        foldSelectorPairs(['vpn-4', 'vpn-4-auto', '🇳🇱 Нидерланды', 'WARP in']),
        ['vpn-4 (vpn-4-auto (🇳🇱 Нидерланды))', 'WARP in'],
      );
    });

    test('исходный список не мутируется', () {
      SelectorInfo.I.setFallbackTags(['vpn-4']);
      final src = ['vpn-4', 'A'];
      foldSelectorPairs(src);
      expect(src, ['vpn-4', 'A']);
    });
  });

  group('SelectorInfo — семантика держателя', () {
    test('setGroups: теги + выборы; clearSelected чистит выборы, теги живут',
        () {
      SelectorInfo.I.setGroups({'vpn-1': 'WARP out', 'vpn-4': '🇳🇱'});
      expect(SelectorInfo.I.isSelector('vpn-4'), true);
      expect(SelectorInfo.I.selectedOf('vpn-4'), '🇳🇱');

      SelectorInfo.I.clearSelected();
      expect(SelectorInfo.I.isSelector('vpn-4'), true); // история фолдится
      expect(SelectorInfo.I.selectedOf('vpn-4'), null);
    });

    test('setFallbackTags: теги без выборов, replace-семантика', () {
      SelectorInfo.I.setFallbackTags(['vpn-2', 'vpn-2-auto']);
      expect(SelectorInfo.I.isSelector('vpn-2-auto'), true);
      expect(SelectorInfo.I.selectedOf('vpn-2'), null);
      // Удалённое Направление уходит при следующем refresh — нода-омоним не
      // фолдится ложно.
      SelectorInfo.I.setFallbackTags(['vpn-1']);
      expect(SelectorInfo.I.isSelector('vpn-2'), false);
    });

    test('свежий снапшот групп замещает и выборы, и kernel-теги целиком', () {
      SelectorInfo.I.setGroups({'vpn-4': 'старый'});
      SelectorInfo.I.setGroups({'vpn-1': 'WARP out'});
      expect(SelectorInfo.I.selectedOf('vpn-4'), null);
      expect(SelectorInfo.I.isSelector('vpn-4'), false); // прошлый конфиг ушёл
      expect(SelectorInfo.I.isSelector('vpn-1'), true);
    });

    test('kernel- и fallback-наборы независимы (union в isSelector)', () {
      SelectorInfo.I.setFallbackTags(['vpn-2']);
      SelectorInfo.I.setGroups({'vpn-1': 'X'});
      expect(SelectorInfo.I.isSelector('vpn-2'), true); // из fallback
      expect(SelectorInfo.I.isSelector('vpn-1'), true); // из kernel
    });
  });

  group('routingLineOf — fold в detour-хвосте, нотация §181 не тронута', () {
    test('TrafficEvent: vpn-4 → 🇳🇱 схлопнуты, ⇒/:/→ на местах', () {
      SelectorInfo.I.setFallbackTags(['vpn-1', 'vpn-4']);
      final e = TrafficEvent(
        ts: DateTime.utc(2026, 7, 6),
        kind: TrafficEventKind.udpOpen,
        network: 'udp',
        ip: '142.250.150.132',
        outboundChain: const ['WARP out', 'vpn-1'],
        detourChain: const ['vpn-4', '🇳🇱 Нидерланды', 'WARP in'],
      );
      expect(
        e.routingLineOf(),
        '[udp] final ⇒ vpn-1 : WARP in → '
        'vpn-4 (🇳🇱 Нидерланды) → vpn-1 (WARP out) → 142.250.150.132',
      );
    });

    test('CcConnection: идентичная строка (§204 — один источник цепочек)',
        () {
      SelectorInfo.I.setFallbackTags(['vpn-1', 'vpn-4']);
      final c = CcConnection(
        id: 'x',
        network: 'udp',
        domain: '',
        destination: '142.250.150.132:443',
        rule: '',
        uplink: 0,
        downlink: 0,
        chains: const ['WARP out', 'vpn-1'],
        detours: const ['vpn-4', '🇳🇱 Нидерланды', 'WARP in'],
        createdAt: 0,
        closedAt: 0,
      );
      expect(
        c.routingLineOf(),
        '[udp] final ⇒ vpn-1 : WARP in → '
        'vpn-4 (🇳🇱 Нидерланды) → vpn-1 (WARP out) → 142.250.150.132',
      );
    });

    test('без detour-Направления строка не меняется (fold = no-op)', () {
      SelectorInfo.I.setFallbackTags(['vpn-1']);
      final e = TrafficEvent(
        ts: DateTime.utc(2026, 7, 6),
        kind: TrafficEventKind.tcpOpen,
        network: 'tcp',
        domain: 'ya.ru',
        outboundChain: const ['node-a', 'vpn-1'],
        detourChain: const ['WARP in'],
      );
      expect(e.routingLineOf(),
          '[tcp] final ⇒ vpn-1 : WARP in → vpn-1 (node-a) → ya.ru');
    });
  });

  group('routingRows (§204) — Detour фолдится, Chain нет', () {
    test('Detour: селектор+выбор в скобках; Chain как есть', () {
      SelectorInfo.I.setFallbackTags(['vpn-1', 'vpn-4']);
      final rows = routingRows(
        route: 'r',
        rule: 'final',
        chain: const ['WARP out', 'vpn-1'],
        detour: const ['vpn-4', '🇳🇱 Нидерланды', 'WARP in'],
      );
      final byLabel = {for (final r in rows) r.label: r.value};
      expect(byLabel['Detour'], 'WARP in → vpn-4 (🇳🇱 Нидерланды)');
      // Chain: [node, …selectors] — выбор ПЕРЕД селектором, пары нет.
      expect(byLabel['Chain'], 'WARP out / vpn-1');
    });
  });

  group('пикер detour (§251) — текущий выбор Направления в скобках', () {
    const relay = Direction(tag: 'vpn-4', isDetour: true);

    test('detourDirectionDisplay: выбор известен → ⚙ label (node)', () {
      SelectorInfo.I.setGroups({'vpn-4': '🇳🇱 Нидерланды'});
      expect(detourDirectionDisplay('vpn-4', const [relay]),
          '⚙ vpn-4 (🇳🇱 Нидерланды)');
    });

    test('detourDirectionDisplay: туннель down → просто ⚙ label', () {
      expect(detourDirectionDisplay('vpn-4', const [relay]), '⚙ vpn-4');
    });

    test('detourDirectionDisplay: auto-двойник тоже находит Направление', () {
      SelectorInfo.I.setGroups({'vpn-4-auto': 'быстрый-node'});
      expect(detourDirectionDisplay('vpn-4-auto', const [relay]),
          '⚙ vpn-4 (быстрый-node)');
    });
  });
}
