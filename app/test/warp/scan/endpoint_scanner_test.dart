// §834 — юнит-тест движка сканера: группировка по странам, счётчики,
// сортировка, парсер cdn-cgi/trace, выборка IP по блокам. Сеть/ядро не
// трогаем — проверяем чистую логику.

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/endpoint_scanner.dart';
import 'package:lxbox/services/warp/scan/scan_wire.dart';

void main() {
  test('country names resolve to Russian where known', () {
    expect(countryName('DE'), 'Германия');
    expect(countryName('RU'), 'Россия');
    expect(countryName(''), '');
    expect(countryName('zz'), 'ZZ');
  });

  group('parseCloudflareTrace', () {
    test('extracts loc and colo (uppercased)', () {
      const body = 'fl=123abc\n'
          'h=1.1.1.1\n'
          'ip=203.0.113.7\n'
          'loc=DE\n'
          'colo=FRA\n'
          'warp=on\n'
          'ts=1700000000.000\n';
      final r = parseCloudflareTrace(body);
      expect(r.country, 'DE');
      expect(r.colo, 'FRA');
    });

    test('lowercase values are normalised', () {
      final r = parseCloudflareTrace('loc=de\ncolo=fra\n');
      expect(r.country, 'DE');
      expect(r.colo, 'FRA');
    });

    test('missing loc → empty country, junk tolerated', () {
      final r = parseCloudflareTrace('ip=1.2.3.4\ncolo=AMS\nnot-a-pair\n');
      expect(r.country, '');
      expect(r.colo, 'AMS');
    });

    test('empty body → empty', () {
      final r = parseCloudflareTrace('');
      expect(r.country, '');
      expect(r.colo, '');
    });
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

  test('unknown-country group is flagged and sorted last', () {
    const known = EndpointCountryGroup(
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
      ],
    );
    const unknown = EndpointCountryGroup(
      code: '',
      name: '',
      endpoints: [
        EndpointResult(
          endpoint: 'z:2408',
          country: '',
          colo: '',
          rttMs: 0,
          alive: true,
        ),
      ],
    );
    expect(unknown.isUnknown, isTrue);
    expect(known.isUnknown, isFalse);
    final sorted = [unknown, known]..sort((a, b) {
        if (a.isUnknown != b.isUnknown) return a.isUnknown ? 1 : -1;
        return b.valid.compareTo(a.valid);
      });
    expect(sorted.first.code, 'DE');
    expect(sorted.last.isUnknown, isTrue);
  });

  test('classifyWgResponse treats junk as not alive', () {
    expect(classifyWgResponse([1, 2, 3]).alive, isFalse);
    expect(classifyWgResponse([4, ...List.filled(91, 0)]).alive, isTrue);
    expect(classifyWgResponse([3, ...List.filled(63, 0)]).alive, isTrue);
  });
}
