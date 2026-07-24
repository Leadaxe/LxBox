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

  group('ScanPool.fromFullJson', () {
    test('парсит wireguard+masque секции и hasData', () {
      final pool = ScanPool.fromFullJson({
        'wireguard': {
          'v4_cidr': ['162.159.192.0/24'],
          'ports': [2408, 500],
          'ports_extra': [7156],
          'sni_pool': ['a'],
          'utls_fp_pool': ['chrome'],
        },
        'masque': {
          'v4_cidr': ['162.159.198.0/24', '162.159.199.0/24'],
          'ports_h3': [443, 4443, 8095],
          'ports_h2': [500, 4500, 8443],
          'sni_pool': ['b'],
        },
      });
      expect(pool, isNotNull);
      expect(pool!.hasData, isTrue);
      expect(pool.wgPorts, [2408, 500]);
      expect(pool.wgPortsExtra, [7156]);
      expect(pool.wgSniPool, ['a']);
      expect(pool.masqueV4Cidr, ['162.159.198.0/24', '162.159.199.0/24']);
      expect(pool.masquePortsH3, [443, 4443, 8095]);
      expect(pool.masquePortsH2, [500, 4500, 8443]);
      expect(pool.masqueSniPool, ['b']);
    });

    test('§305 — masquePortsFor разделяет h3/h2', () {
      final pool = ScanPool.fromFullJson({
        'masque': {
          'v4_cidr': ['162.159.198.0/24'],
          'ports_h3': [443, 4443],
          'ports_h2': [500, 8443],
        },
      });
      expect(pool!.masquePortsFor('h3'), [443, 4443]);
      expect(pool.masquePortsFor('h2'), [500, 8443]);
      // Неизвестный транспорт → h3-набор дефолтом.
      expect(pool.masquePortsFor('foo'), [443, 4443]);
    });

    test('null / пустой → null', () {
      expect(ScanPool.fromFullJson(null), isNull);
      expect(
        ScanPool.fromFullJson({}),
        isNull,
        reason: 'нет диапазонов → hasData=false → null',
      );
    });

    test('masque-only (без wg) → hasData true, не null', () {
      final pool = ScanPool.fromFullJson({
        'masque': {
          'v4_cidr': ['162.159.198.0/24'],
          'ports_h3': [443],
          'ports_h2': [500],
          'sni_pool': ['y'],
        },
      });
      expect(pool, isNotNull);
      expect(pool!.hasData, isTrue);
      expect(pool.wgPorts, isEmpty);
    });
  });
}
