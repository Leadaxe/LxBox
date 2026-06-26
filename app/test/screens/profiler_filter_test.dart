import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/traffic_profiler.dart';
import 'package:lxbox/screens/stats_screen/profiler_filter.dart';
import 'package:lxbox/screens/per_app_trace_tab/session_json.dart';

/// §044/new-profiler — тесты фильтр-модели (ортогональность осей app/тип,
/// includeApps-флаг для App-вкладки, §177 family) и eventsToJson.

TrafficEvent _ev({
  required TrafficEventKind kind,
  String? domain,
  String? ip,
  String? process,
  ConfidenceLevel confidence = ConfidenceLevel.verified,
}) =>
    TrafficEvent(
      ts: DateTime(2026, 6, 26, 12, 0, 0),
      kind: kind,
      domain: domain,
      ip: ip,
      process: process,
      confidence: confidence,
    );

void main() {
  group('ProfilerFilter — оси', () {
    late ProfilerFilter f;
    late List<TrafficEvent> events;

    setUp(() {
      f = ProfilerFilter();
      events = [
        _ev(
            kind: TrafficEventKind.tcpOpen,
            domain: 'chrome.example',
            process: 'com.android.chrome'),
        _ev(
            kind: TrafficEventKind.dnsResolve,
            domain: 'gms.example',
            process: 'com.google.android.gms'),
        _ev(
            kind: TrafficEventKind.dnsFail,
            domain: 'chrome.fail',
            process: 'com.android.chrome'),
        _ev(
            kind: TrafficEventKind.udpOpen,
            ip: '1.2.3.4',
            process: 'org.telegram.messenger'),
      ];
    });

    test('пустой фильтр пропускает всё', () {
      expect(f.apply(events).length, 4);
      expect(f.isActive, isFalse);
      expect(f.activeCount, 0);
    });

    test('app-ось: только выбранный пакет', () {
      f.toggleApp('com.android.chrome', true);
      final out = f.apply(events).toList();
      expect(out.length, 2);
      expect(out.every((e) => e.process == 'com.android.chrome'), isTrue);
    });

    test('kind-ось по семейству §177: DNS ловит resolve+fail', () {
      f.toggleKind(TrafficEventKind.dnsResolve, true);
      final out = f.apply(events).toList();
      expect(out.length, 2); // dnsResolve + dnsFail
      expect(
          out.every((e) =>
              e.kind == TrafficEventKind.dnsResolve ||
              e.kind == TrafficEventKind.dnsFail),
          isTrue);
    });

    test('оси ортогональны: app + тип одновременно', () {
      f.toggleApp('com.android.chrome', true);
      f.toggleKind(TrafficEventKind.dnsResolve, true);
      final out = f.apply(events).toList();
      // chrome + DNS-family → только dnsFail у chrome (chrome.fail)
      expect(out.length, 1);
      expect(out.single.domain, 'chrome.fail');
    });

    test('includeApps=false (App-вкладка): app-ось игнорится', () {
      f.toggleApp('com.android.chrome', true);
      // С includeApps=false выбор app не сужает список.
      final out = f.apply(events, includeApps: false).toList();
      expect(out.length, 4);
    });

    test('search матчит domain / ip / process', () {
      f.search = 'telegram';
      expect(f.apply(events).single.process, 'org.telegram.messenger');
      f.search = '1.2.3.4';
      expect(f.apply(events).single.ip, '1.2.3.4');
    });

    test('onlyUnattributed', () {
      final mixed = [
        ...events,
        _ev(
            kind: TrafficEventKind.tcpOpen,
            domain: 'noowner.example',
            confidence: ConfidenceLevel.unattributed),
      ];
      f.onlyUnattributed = true;
      expect(f.apply(mixed).single.domain, 'noowner.example');
    });

    test('activeCount считает оси', () {
      f.toggleApp('com.android.chrome', true);
      f.toggleApp('org.telegram.messenger', true);
      f.toggleKind(TrafficEventKind.dnsResolve, true);
      f.search = 'x';
      f.onlyUnattributed = true;
      expect(f.activeCount, 5); // 2 app + 1 kind + search + unattr
      f.clearAll();
      expect(f.activeCount, 0);
    });

    test('kindFamily: fail/close сводятся к базовому', () {
      expect(ProfilerFilter.kindFamily(TrafficEventKind.dnsFail),
          TrafficEventKind.dnsResolve);
      expect(ProfilerFilter.kindFamily(TrafficEventKind.tcpClose),
          TrafficEventKind.tcpOpen);
      expect(ProfilerFilter.kindFamily(TrafficEventKind.udpOpen),
          TrafficEventKind.udpOpen);
    });
  });

  group('eventsToJson', () {
    test('сериализует список + пересчитанные агрегаты', () {
      final events = [
        _ev(
            kind: TrafficEventKind.tcpOpen,
            domain: 'a.example',
            ip: '10.0.0.1',
            process: 'com.x'),
        _ev(
            kind: TrafficEventKind.dnsResolve,
            domain: 'b.example',
            process: 'com.y'),
      ];
      final json = eventsToJson(events);
      expect(json['event_count'], 2);
      expect((json['events'] as List).length, 2);
      expect(json['exported_at'], isA<String>());
      // by_domain содержит оба домена (verified → попадают в агрегат).
      final domains = (json['by_domain'] as List)
          .map((d) => (d as Map)['domain'])
          .toList();
      expect(domains, containsAll(['a.example', 'b.example']));
    });

    test('unattributed события не пачкают агрегаты (как Session)', () {
      final events = [
        _ev(
            kind: TrafficEventKind.tcpOpen,
            domain: 'noowner.example',
            confidence: ConfidenceLevel.unattributed),
      ];
      final json = eventsToJson(events);
      expect(json['event_count'], 1); // в events попадает
      expect((json['by_domain'] as List), isEmpty); // в агрегат — нет
    });
  });
}
