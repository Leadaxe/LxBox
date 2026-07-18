import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/scan_pool.dart';

/// §284 — пул скана: парс `scan`-блока + CIDR→random IP в границах подсети.
void main() {
  /// Истинно, если [ip] попадает в [cidr] (bitmask-сравнение, v4+v6).
  bool inCidr(String ip, String cidr) {
    final parts = cidr.split('/');
    final net = InternetAddress(parts[0]).rawAddress;
    final a = InternetAddress(ip).rawAddress;
    if (net.length != a.length) return false;
    var bits = int.parse(parts[1]);
    for (var i = 0; i < net.length; i++) {
      if (bits >= 8) {
        if (net[i] != a[i]) return false;
        bits -= 8;
      } else if (bits > 0) {
        final m = (0xff << (8 - bits)) & 0xff;
        if ((net[i] & m) != (a[i] & m)) return false;
        bits = 0;
      } else {
        break;
      }
    }
    return true;
  }

  group('randomIpInCidr', () {
    final rng = Random(42);
    for (final cidr in [
      '162.159.192.0/24',
      '188.114.96.0/22',
      '2606:4700:d0::/64',
    ]) {
      test('$cidr → все 500 адресов внутри подсети', () {
        for (var i = 0; i < 500; i++) {
          final ip = randomIpInCidr(cidr, rng);
          expect(inCidr(ip, cidr), isTrue, reason: '$ip not in $cidr');
        }
      });
    }

    test('/32 возвращает сам адрес', () {
      expect(randomIpInCidr('162.159.192.7/32', Random(1)), '162.159.192.7');
    });

    test('битый CIDR → FormatException', () {
      expect(() => randomIpInCidr('162.159.192.0', Random(1)),
          throwsFormatException);
    });
  });

  group('ScanPool.fromJson', () {
    test('парсит scan-блок и hasData', () {
      final pool = ScanPool.fromJson(
        {
          'wg_v4_cidr': ['162.159.192.0/24'],
          'wg_ports': [2408, 500],
          'wg_ports_empirical': [7156],
          'masque_v4_cidr': ['162.159.198.0/24'],
          'masque_port': 443,
          'utls_fp_pool': ['chrome'],
        },
        sniPool: ['a'],
        masqueSniPool: ['b'],
      );
      expect(pool, isNotNull);
      expect(pool!.hasData, isTrue);
      expect(pool.wgPorts, [2408, 500]);
      expect(pool.masquePort, 443);
      expect(pool.sniPool, ['a']);
    });

    test('null / пустой блок → null', () {
      expect(ScanPool.fromJson(null, sniPool: [], masqueSniPool: []), isNull);
      expect(
        ScanPool.fromJson({}, sniPool: [], masqueSniPool: []),
        isNull,
        reason: 'нет диапазонов → hasData=false → null',
      );
    });

    test('masque-only (без wg-портов) → hasData true, не null', () {
      final pool = ScanPool.fromJson(
        {
          'masque_v4_cidr': ['162.159.198.0/24'],
          'masque_port': 443,
        },
        sniPool: [],
        masqueSniPool: ['y'],
      );
      expect(pool, isNotNull);
      expect(pool!.hasData, isTrue);
      expect(pool.wgPorts, isEmpty);
    });
  });
}
