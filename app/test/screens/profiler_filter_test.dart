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
  String? rule,
  List<String> outboundChain = const [],
  List<String> detourChain = const [],
  ConfidenceLevel confidence = ConfidenceLevel.verified,
}) =>
    TrafficEvent(
      ts: DateTime(2026, 6, 26, 12, 0, 0),
      kind: kind,
      domain: domain,
      ip: ip,
      process: process,
      rule: rule,
      outboundChain: outboundChain,
      detourChain: detourChain,
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

    test('потеряшки (includeUnattributed) — OR с выбранными app', () {
      final mixed = [
        ...events,
        _ev(
            kind: TrafficEventKind.tcpOpen,
            domain: 'noowner.example',
            confidence: ConfidenceLevel.unattributed),
      ];
      // Только потеряшки: chrome не выбран → лишь noowner.
      f.includeUnattributed = true;
      expect(f.apply(mixed).single.domain, 'noowner.example');
      // Chrome + потеряшки: OR → chrome-события И noowner.
      f.toggleApp('com.android.chrome', true);
      final out = f.apply(mixed).toList();
      expect(out.length, 3); // 2 chrome + 1 noowner
      expect(out.any((e) => e.domain == 'noowner.example'), isTrue);
      expect(out.any((e) => e.process == 'com.android.chrome'), isTrue);
    });

    test('activeCount считает оси', () {
      f.toggleApp('com.android.chrome', true);
      f.toggleApp('org.telegram.messenger', true);
      f.toggleKind(TrafficEventKind.dnsResolve, true);
      f.search = 'x';
      f.includeUnattributed = true;
      expect(f.activeCount, 5); // 2 app + 1 kind + search + unattr
      // App-вкладка: activeCountNoApps игнорит app-ось.
      expect(f.activeCountNoApps, 2); // 1 kind + search
      f.clearAll();
      expect(f.activeCount, 0);
    });

    test('appAxisActive: app или потеряшки', () {
      expect(f.appAxisActive, isFalse);
      f.includeUnattributed = true;
      expect(f.appAxisActive, isTrue);
      f.includeUnattributed = false;
      f.toggleApp('com.x', true);
      expect(f.appAxisActive, isTrue);
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

  group('ProfilerFilter — оси Rule/Outbound (§230)', () {
    late ProfilerFilter f;
    late List<TrafficEvent> events;

    setUp(() {
      f = ProfilerFilter();
      events = [
        _ev(
            kind: TrafficEventKind.tcpOpen,
            domain: 'a.ru',
            rule: 'ru-direct',
            outboundChain: ['node-1', 'vpn-1']),
        _ev(
            kind: TrafficEventKind.tcpOpen,
            domain: 'b.com',
            rule: 'fakeip',
            outboundChain: ['node-2', '✨auto', 'vpn-1'],
            detourChain: ['WARP']),
        _ev(
            kind: TrafficEventKind.tcpOpen,
            domain: 'c.com',
            rule: null, // без правила → «final»
            outboundChain: ['direct-out']),
      ];
    });

    test('rule-ось: только выбранное правило', () {
      f.toggleRule('ru-direct', true);
      final out = f.apply(events).toList();
      expect(out.single.domain, 'a.ru');
    });

    test('rule-ось: пустой rule ловится как «final» ('' в наборе)', () {
      f.toggleRule('', true);
      final out = f.apply(events).toList();
      expect(out.single.domain, 'c.com');
    });

    test('rule-ось OR: два правила', () {
      f.toggleRule('ru-direct', true);
      f.toggleRule('fakeip', true);
      expect(f.apply(events).length, 2);
    });

    test('outbound-ось: любое звено outboundChain', () {
      f.toggleOutbound('vpn-1', true);
      final out = f.apply(events).toList();
      // vpn-1 есть в цепочках a.ru и b.com (не в direct-out).
      expect(out.length, 2);
      expect(out.map((e) => e.domain), containsAll(['a.ru', 'b.com']));
    });

    test('outbound-ось: ловит detour-звено (WARP)', () {
      f.toggleOutbound('WARP', true);
      expect(f.apply(events).single.domain, 'b.com');
    });

    test('rule + outbound ортогональны (AND между осями)', () {
      f.toggleRule('fakeip', true);
      f.toggleOutbound('vpn-1', true);
      // fakeip И vpn-1 в цепочке → только b.com.
      expect(f.apply(events).single.domain, 'b.com');
    });

    test('activeCount учитывает rule+outbound; clearAll сбрасывает', () {
      f.toggleRule('ru-direct', true);
      f.toggleOutbound('vpn-1', true);
      f.toggleOutbound('WARP', true);
      expect(f.activeCount, 3); // 1 rule + 2 outbound
      f.clearAll();
      expect(f.activeCount, 0);
      expect(f.apply(events).length, 3);
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
