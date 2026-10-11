// §834 — юнит-тест движка сканера: группировка по странам, счётчики,
// сортировка, парсер cdn-cgi/trace, выборка IP по блокам. Сеть/ядро не
// трогаем — проверяем чистую логику.

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/parser/mappers/uri_pipeline.dart'
    show parseLinkViaPipeline;
import 'package:lxbox/services/probe/probe_config.dart';
import 'package:lxbox/services/warp/scan/endpoint_scanner.dart';
import 'package:lxbox/services/warp/scan/scan_models.dart';
import 'package:lxbox/services/warp/scan/scan_node_builder.dart';
import 'package:lxbox/services/warp/scan/scan_wire.dart';
import 'package:lxbox/services/warp/warp_account.dart';

import '../../parser/engine_test_setup.dart';

void main() {
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

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
    expect(classifyWgResponse([2, ...List.filled(91, 0)]).alive, isTrue);
    expect(classifyWgResponse([3, ...List.filled(63, 0)]).alive, isTrue);
  });

  test(
    'фаза 2 строит рабочий probe-конфиг ядра под конкретный эндпоинт '
    '(это и есть суть фикса: без сессии страна/valid были пусты)',
    () {
      const acc = WarpAccount(
        privKey: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=',
        peerPub: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=',
        clientV4: '172.16.0.2/32',
        clientV6: '',
        clientId: 'AAAA',
        accountId: 'acc',
        deviceId: 'dev',
        token: 'tok',
        endpoint: 'engage.cloudflareclient.com:2408',
        createdAt: '2026-01-01T00:00:00Z',
      );
      final builder = ScanNodeBuilder(warp: acc);

      // Тот же путь, что у сканера: ScanCandidate → URI → parseUri → узел.
      final candidate = const ScanCandidate(
        ip: '162.159.192.7',
        port: 2408,
        protocol: ScanProtocol.awg,
        sni: 'www.google.com',
        awgParams: AwgParams(ip: 'quic', jc: 4, jmin: 40, jmax: 70),
      );
      final uri = builder.uriFor(candidate);
      expect(uri, isNotNull);
      final node = parseLinkViaPipeline(uri!);
      expect(node, isA<WireguardSpec>());

      // Узел собирается в probe-конфиг с реальным тегом (не фиктивным
      // `ep_<addr>`) — именно его зовёт probeGetUrl.
      final cfg = buildProbeConfig([node]);
      expect(cfg.configJson, isNotNull);
      expect(cfg.tagByIndex[0], isNotNull);
      expect(cfg.tagByIndex[0], isNot(contains('162.159.192.7')),
          reason: 'тег ядра — из allocate(), а не адрес');
      final decoded = cfg.configJson!;
      expect(decoded, contains('162.159.192.7'));
      expect(decoded, contains('endpoints'));
    },
  );
}
