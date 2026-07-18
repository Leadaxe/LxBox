import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/candidate_generator.dart';
import 'package:lxbox/services/warp/scan/scan_models.dart';
import 'package:lxbox/services/warp/scan/scan_pool.dart';

/// §284 — генератор кандидатов для рандом-скана (фаза 1 посев + фаза 2 вариации).
void main() {
  ScanPool fullPool() => const ScanPool(
        wgV4Cidr: ['162.159.192.0/24', '188.114.96.0/22'],
        wgV6Cidr: ['2606:4700:d0::/64'],
        wgPorts: [2408, 500, 1701, 4500],
        wgPortsEmpirical: [854, 7156],
        masqueV4Cidr: ['162.159.198.0/24'],
        masquePort: 443,
        utlsFpPool: ['chrome', 'firefox', 'safari'],
        sniPool: ['www.google.com', 'yandex.ru'],
        masqueSniPool: ['www.cloudflare.com', 'yandex.ru'],
      );

  group('seed', () {
    test('возвращает ровно n кандидатов', () {
      final g = CandidateGenerator(fullPool(), rng: Random(1));
      expect(g.seed(100).length, 100);
      expect(g.seed(0), isEmpty);
    });

    test('порт согласован с протоколом; masque=443, wg=из wg-портов', () {
      final g = CandidateGenerator(fullPool(), rng: Random(7));
      final wgPorts = {2408, 500, 1701, 4500, 854, 7156};
      for (final c in g.seed(200)) {
        if (c.protocol == ScanProtocol.awg) {
          expect(wgPorts.contains(c.port), isTrue, reason: 'wg port ${c.port}');
        } else {
          expect(c.port, 443, reason: 'masque port');
        }
      }
    });

    test('SNI берётся из соответствующего пула', () {
      final g = CandidateGenerator(fullPool(), rng: Random(3));
      const wgSni = {'www.google.com', 'yandex.ru'};
      const masqueSni = {'www.cloudflare.com', 'yandex.ru'};
      for (final c in g.seed(100)) {
        final pool = c.protocol == ScanProtocol.awg ? wgSni : masqueSni;
        expect(pool.contains(c.sni), isTrue, reason: 'sni ${c.sni}');
      }
    });

    test('покрывает все три протокола при полном пуле', () {
      final g = CandidateGenerator(fullPool(), rng: Random(11));
      final protos = g.seed(300).map((c) => c.protocol).toSet();
      expect(protos, containsAll(ScanProtocol.values));
    });

    test('только masque, если нет wg-диапазонов', () {
      const pool = ScanPool(
        wgV4Cidr: [],
        wgV6Cidr: [],
        wgPorts: [443],
        wgPortsEmpirical: [],
        masqueV4Cidr: ['162.159.198.0/24'],
        masquePort: 443,
        utlsFpPool: ['chrome'],
        sniPool: [],
        masqueSniPool: ['yandex.ru'],
      );
      final g = CandidateGenerator(pool, rng: Random(5));
      final protos = g.seed(50).map((c) => c.protocol).toSet();
      expect(protos.contains(ScanProtocol.awg), isFalse);
      expect(protos.every((p) => p.isMasque), isTrue);
    });

    test('wg-диапазон, но БЕЗ wg-портов → только masque, без краша', () {
      const pool = ScanPool(
        wgV4Cidr: ['162.159.192.0/24'],
        wgV6Cidr: [],
        wgPorts: [],
        wgPortsEmpirical: [],
        masqueV4Cidr: ['162.159.198.0/24'],
        masquePort: 443,
        utlsFpPool: ['chrome'],
        sniPool: [],
        masqueSniPool: ['y'],
      );
      final g = CandidateGenerator(pool, rng: Random(8));
      final protos = g.seed(30).map((c) => c.protocol).toSet();
      expect(protos.contains(ScanProtocol.awg), isFalse,
          reason: 'awg исключён без wg-портов');
      expect(protos.every((p) => p.isMasque), isTrue);
    });
  });

  group('variations (фаза 2)', () {
    test('покрывает все доступные протоколы для одного IP и держит лимит', () {
      final g = CandidateGenerator(fullPool(), rng: Random(9));
      final v = g.variations('162.159.198.7', limit: 12);
      expect(v.length, lessThanOrEqualTo(12));
      expect(v.map((c) => c.protocol).toSet(), containsAll(ScanProtocol.values));
      expect(v.every((c) => c.ip == '162.159.198.7'), isTrue);
    });
  });
}
