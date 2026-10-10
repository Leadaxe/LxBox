// §834 — тест ScanPool.fromEndpoints: пул из отсканированных эндпоинтов
// превращается в /32-CIDR для WG и h2, а hasData валиден.

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/scan_pool.dart';

void main() {
  test('fromEndpoints builds /32 pool with hasData', () {
    final pool = ScanPool.fromEndpoints([
      '162.159.192.1:2408',
      '162.159.193.1:2408',
      '188.114.96.1:2408',
    ]);
    expect(pool, isNotNull);
    expect(pool!.wgV4Cidr, contains('162.159.192.1/32'));
    expect(pool.wgV4Cidr, contains('162.159.193.1/32'));
    expect(pool.wgV4Cidr, contains('188.114.96.1/32'));
    expect(pool.masqueV4Cidr, contains('162.159.192.1/32'));
    expect(pool.wgPorts, isNotEmpty);
    expect(pool.hasData, isTrue);
  });

  test('fromEndpoints empty returns null', () {
    expect(ScanPool.fromEndpoints([]), isNull);
  });

  test('fromEndpoints dedupes and strips ports in cidr', () {
    final pool = ScanPool.fromEndpoints([
      '1.2.3.4:2408',
      '1.2.3.4:2408', // дубль
      '5.6.7.8',
    ]);
    expect(pool, isNotNull);
    expect(pool!.wgV4Cidr.length, 2);
    expect(pool.wgV4Cidr, contains('1.2.3.4/32'));
    expect(pool.wgV4Cidr, contains('5.6.7.8/32'));
  });

  test('fromEndpoints preserves base sni/ports when base given', () {
    final base = ScanPool(
      wgV4Cidr: const ['10.0.0.0/30'],
      wgV6Cidr: const [],
      wgPorts: const [2408],
      wgPortsExtra: const [],
      wgSniPool: const ['ya.ru'],
      utlsFpPool: const ['chrome'],
      masqueV4Cidr: const ['10.0.1.0/30'],
      masquePortsH3: const [443],
      masquePortsH2: const [500],
      masqueSniPool: const ['consumer-masque.cloudflareclient.com'],
    );
    final pool = ScanPool.fromEndpoints(['9.9.9.9:2408'], base: base);
    expect(pool, isNotNull);
    expect(pool!.wgSniPool, contains('ya.ru'));
    expect(pool.masquePortsH3, contains(443));
    expect(pool.masqueRecommendedSni, '');
  });
}
