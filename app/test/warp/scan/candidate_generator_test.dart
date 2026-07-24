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
        wgPortsExtra: [854, 7156],
        wgSniPool: ['www.google.com', 'yandex.ru'],
        utlsFpPool: ['chrome', 'firefox', 'safari'],
        masqueV4Cidr: ['162.159.198.0/24', '162.159.199.0/24'],
        masqueH3V4Cidr: ['162.159.198.1/32', '162.159.199.1/32'],
        masquePortsH3: [443, 4443, 8095],
        masquePortsH2: [500, 4500, 8443],
        masqueSniPool: ['www.cloudflare.com', 'yandex.ru'],
      );

  group('seed', () {
    test('возвращает ровно n кандидатов', () {
      final g = CandidateGenerator(fullPool(), rng: Random(1));
      expect(g.seed(100).length, 100);
      expect(g.seed(0), isEmpty);
    });

    test('§305 — порт согласован с протоколом; masque h3/h2 раздельно', () {
      final g = CandidateGenerator(fullPool(), rng: Random(7));
      final wgPorts = {2408, 500, 1701, 4500, 854, 7156};
      const h3 = {443, 4443, 8095};
      const h2 = {500, 4500, 8443};
      var sawH3 = false, sawH2 = false;
      for (final c in g.seed(400)) {
        if (c.protocol == ScanProtocol.awg) {
          expect(wgPorts.contains(c.port), isTrue, reason: 'wg port ${c.port}');
        } else if (c.protocol == ScanProtocol.masqueH3) {
          expect(h3.contains(c.port), isTrue, reason: 'h3 port ${c.port}');
          sawH3 = true;
        } else {
          expect(h2.contains(c.port), isTrue, reason: 'h2 port ${c.port}');
          sawH2 = true;
        }
      }
      expect(sawH3 && sawH2, isTrue, reason: 'оба транспорта встретились');
    });

    test('§305 — h3-IP ТОЛЬКО из h3-списка; h2-IP из блока', () {
      final g = CandidateGenerator(fullPool(), rng: Random(13));
      // fullPool: h3_v4_cidr = .198.1/.199.1 (/32); h2 v4_cidr = /24 блоки.
      const h3hosts = {'162.159.198.1', '162.159.199.1'};
      var sawH3 = false, sawH2 = false;
      for (final c in g.seed(400)) {
        if (c.protocol == ScanProtocol.masqueH3) {
          expect(h3hosts.contains(c.ip), isTrue,
              reason: 'h3 IP ${c.ip} должен быть из h3-списка');
          sawH3 = true;
        } else if (c.protocol == ScanProtocol.masqueH2) {
          // h2 — по блоку, октет варьируется (не только .1).
          expect(c.ip.startsWith('162.159.198.') ||
              c.ip.startsWith('162.159.199.'), isTrue);
          sawH2 = true;
        }
      }
      expect(sawH3 && sawH2, isTrue);
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
        wgPortsExtra: [],
        wgSniPool: [],
        utlsFpPool: ['chrome'],
        masqueV4Cidr: ['162.159.198.0/24'],
        masqueH3V4Cidr: [], // фолбэк на блок при пустом h3-списке
        masquePortsH3: [443],
        masquePortsH2: [500],
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
        wgPortsExtra: [],
        wgSniPool: [],
        utlsFpPool: ['chrome'],
        masqueV4Cidr: ['162.159.198.0/24'],
        masqueH3V4Cidr: [], // фолбэк на блок при пустом h3-списке
        masquePortsH3: [443],
        masquePortsH2: [500],
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
