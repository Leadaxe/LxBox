import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/traffic_profiler.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §315 — трасса DNS-группы (kernel SPEC 035) в профайлере: маппинг полей
/// стрима + перенос в `TrafficEvent.extra` для detail-sheet.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> queryMap({
    bool failed = false,
    List<String> groupPath = const [],
    List<Map<String, dynamic>> attempts = const [],
    bool fanned = false,
    bool survival = false,
  }) => {
        'domain': 'example.com',
        'queryType': 1,
        'rcode': failed ? -1 : 0,
        'source': failed ? 'failed' : 'exchanged',
        'failed': failed,
        'error': failed ? 'timeout' : '',
        'dnsServer': 'dns_shield',
        'dnsServerType': 'group',
        'groupPath': groupPath,
        'attempts': attempts,
        'fanned': fanned,
        'survival': survival,
      };

  group('§315 CcDnsQuery — маппинг трассы', () {
    test('все поля группы читаются', () {
      final q = CcDnsQuery.fromMap(queryMap(
        groupPath: ['dns_shield'],
        attempts: [
          {
            'server': 'google_udp',
            'serverType': 'udp',
            'outcome': 'answered',
            'rttMs': 12,
          },
          {
            'server': 'quad9_doh',
            'serverType': 'https',
            'outcome': 'timeout',
            'rttMs': 0,
          },
        ],
        fanned: true,
      ));
      expect(q.groupPath, ['dns_shield']);
      expect(q.viaGroup, isTrue);
      expect(q.fanned, isTrue);
      expect(q.survival, isFalse);
      expect(q.attempts, hasLength(2));
      expect(q.attempts.first.server, 'google_udp');
      expect(q.attempts.first.serverType, 'udp');
      expect(q.attempts.first.rttMs, 12);
      expect(q.attempts.first.answered, isTrue);
      expect(q.attempts.last.outcome, 'timeout');
      expect(q.attempts.last.answered, isFalse);
    });

    test('вложенные группы: путь изнутри наружу', () {
      final q = CcDnsQuery.fromMap(queryMap(groupPath: ['inner', 'outer']));
      expect(q.groupPath, ['inner', 'outer']);
    });

    test('старое ядро (ключей нет) → пустые дефолты, не бросает', () {
      final q = CcDnsQuery.fromMap({
        'domain': 'example.com',
        'queryType': 1,
        'rcode': 0,
      });
      expect(q.groupPath, isEmpty);
      expect(q.attempts, isEmpty);
      expect(q.fanned, isFalse);
      expect(q.survival, isFalse);
      expect(q.viaGroup, isFalse);
    });

    test('битые attempts не роняют парс', () {
      final q = CcDnsQuery.fromMap({
        ...queryMap(),
        'attempts': ['мусор', 42, null],
      });
      expect(q.attempts, isEmpty);
    });
  });

  group('§315 профайлер — трасса в extra', () {
    // `startGlobalRecording` идемпотентен (§048: повторный вызов = no-op,
    // буфер НЕ чистит) — профайлер синглтон, события копятся между тестами.
    // Берём последнее DNS-событие, а не единственное.
    TrafficEvent ingestOne(Map<String, dynamic> m) {
      TrafficProfiler.I.startGlobalRecording();
      final before = TrafficProfiler.I.globalRollingBuffer.length;
      TrafficProfiler.I.ingestDnsForTest([CcDnsQuery.fromMap(m)]);
      final fresh = TrafficProfiler.I.globalRollingBuffer
          .skip(before)
          .where((e) =>
              e.kind == TrafficEventKind.dnsResolve ||
              e.kind == TrafficEventKind.dnsFail)
          .toList();
      expect(fresh, hasLength(1), reason: 'событие не доехало в буфер');
      return fresh.single;
    }

    test('веер: путь, пробы и флаг fanned в extra', () {
      final e = ingestOne(queryMap(
        groupPath: ['dns_shield'],
        attempts: [
          {
            'server': 'google_udp',
            'serverType': 'udp',
            'outcome': 'timeout',
            'rttMs': 0,
          },
          {
            'server': 'cloudflare_udp',
            'serverType': 'udp',
            'outcome': 'answered',
            'rttMs': 8,
          },
        ],
        fanned: true,
      ));
      expect(e.kind, TrafficEventKind.dnsResolve);
      expect(e.extra?['dns_group_path'], 'dns_shield');
      expect(e.extra?['dns_attempts'],
          'google_udp timeout · cloudflare_udp answered 8ms');
      expect(e.extra?['dns_fanned'], 'true');
      expect(e.extra?['dns_survival'], isNull);
    });

    test('survival попадает в extra (красный флаг здоровья)', () {
      final e = ingestOne(queryMap(
        groupPath: ['dns_shield'],
        attempts: [
          {
            'server': 'yandex_udp',
            'serverType': 'udp',
            'outcome': 'answered',
            'rttMs': 300,
          },
        ],
        survival: true,
      ));
      expect(e.extra?['dns_survival'], 'true');
      expect(e.extra?['dns_fanned'], isNull);
    });

    test('НЕ групповой запрос → ключей трассы нет (не мусорим extra)', () {
      final e = ingestOne(queryMap());
      expect(e.extra?['dns_group_path'], isNull);
      expect(e.extra?['dns_attempts'], isNull);
      expect(e.extra?['dns_fanned'], isNull,
          reason: 'false-флаги не пишем — 99% трафика идёт мимо групп');
      expect(e.extra?['dns_survival'], isNull);
      // Существующие поля не задеты.
      expect(e.extra?['dns_server'], 'dns_shield');
    });

    test('dnsFail тоже несёт трассу (на провале она важнее всего)', () {
      final e = ingestOne(queryMap(
        failed: true,
        groupPath: ['dns_shield'],
        attempts: [
          {
            'server': 'google_udp',
            'serverType': 'udp',
            'outcome': 'timeout',
            'rttMs': 0,
          },
          {
            'server': 'quad9_doh',
            'serverType': 'https',
            'outcome': 'servfail',
            'rttMs': 45,
          },
        ],
        fanned: true,
      ));
      expect(e.kind, TrafficEventKind.dnsFail);
      expect(e.extra?['dns_group_path'], 'dns_shield');
      expect(e.extra?['dns_attempts'],
          'google_udp timeout · quad9_doh servfail 45ms');
      expect(e.extra?['dns_fanned'], 'true');
    });

    test('кеш-попадание: attempts пусто (контракт ядра SPEC 035)', () {
      final e = ingestOne({
        ...queryMap(groupPath: ['dns_shield']),
        'source': 'cached',
      });
      expect(e.extra?['dns_group_path'], 'dns_shield');
      expect(e.extra?['dns_attempts'], isNull);
    });
  });
}
