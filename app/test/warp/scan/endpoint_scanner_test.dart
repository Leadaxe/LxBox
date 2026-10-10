// §834 — юнит-тест движка сканера: группировка по странам, счётчики,
// сортировка, отмена. Сеть/ядро не трогаем — проверяем чистую логику.

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/endpoint_scanner.dart';
import 'package:lxbox/services/warp/scan/scan_wire.dart';

void main() {
  test('country names resolve to Russian where known', () {
    expect(countryName('DE'), 'Германия');
    expect(countryName('RU'), 'Россия');
    expect(countryName('??'), '??');
    expect(countryName('zz'), 'ZZ');
  });

  test('groups sort by valid count desc and count found/valid', () {
    const g1 = EndpointCountryGroup(
      code: 'DE',
      name: 'Германия',
      endpoints: [
        EndpointResult(
          endpoint: 'a:2408',
          country: 'DE',
          colo: 'FRA',
          rttMs: 10,
          alive: true,
        ),
        EndpointResult(
          endpoint: 'b:2408',
          country: 'DE',
          colo: 'FRA',
          rttMs: 20,
          alive: true,
        ),
      ],
    );
    const g0 = EndpointCountryGroup(
      code: 'NL',
      name: 'Нидерланды',
      endpoints: [
        EndpointResult(
          endpoint: 'c:2408',
          country: 'NL',
          colo: 'AMS',
          rttMs: 5,
          alive: false,
        ),
      ],
    );
    final sorted = [g0, g1]..sort((a, b) => b.valid.compareTo(a.valid));
    expect(sorted.first.code, 'DE');
    expect(sorted.first.found, 2);
    expect(sorted.first.valid, 2);
    expect(sorted.last.valid, 0);

    final result = EndpointScanResult(
      groups: [g1, g0],
      scanAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      scanDurationMs: 100,
      failedCount: 3,
    );
    expect(result.totalFound, 3);
    expect(result.totalValid, 2);
  });

  test('classifyWgResponse treats junk as not alive', () {
    expect(classifyWgResponse([1, 2, 3]).alive, isFalse);
    expect(classifyWgResponse([4, ...List.filled(91, 0)]).alive, isTrue);
    expect(classifyWgResponse([3, ...List.filled(63, 0)]).alive, isTrue);
  });
}
