// §044 — TrafficProfiler unit tests.

import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/traffic_profiler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TrafficProfiler.I.resetForTesting();
  });

  group('TrafficProfiler — session lifecycle', () {
    test('start sets active', () async {
      final s = await TrafficProfiler.I.start('ru.tinkoff.investing');
      expect(s.targetPackage, 'ru.tinkoff.investing');
      expect(TrafficProfiler.I.isRecording, true);
      expect(TrafficProfiler.I.active!.id, s.id);
    });

    test('stop moves to completed', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      final s = await TrafficProfiler.I.stop();
      expect(s, isNotNull);
      expect(TrafficProfiler.I.isRecording, false);
      expect(TrafficProfiler.I.completed.length, 1);
      expect(TrafficProfiler.I.completed.first.id, s!.id);
    });

    test('start while active finalizes previous', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      await TrafficProfiler.I.start('org.telegram.messenger');
      expect(TrafficProfiler.I.completed.length, 1);
      expect(TrafficProfiler.I.completed.first.targetPackage,
          'ru.tinkoff.investing');
      expect(TrafficProfiler.I.active!.targetPackage, 'org.telegram.messenger');
    });

    test('completed ring-buffer cap = 5', () async {
      for (var i = 0; i < 7; i++) {
        await TrafficProfiler.I.start('app.$i');
        await TrafficProfiler.I.stop();
      }
      expect(TrafficProfiler.I.completed.length, 5);
      // Oldest (app.0, app.1) сброшены.
      final pkgs = TrafficProfiler.I.completed.map((s) => s.targetPackage);
      expect(pkgs.contains('app.0'), false);
      expect(pkgs.contains('app.6'), true);
    });

    test('delete removes from completed', () async {
      await TrafficProfiler.I.start('a');
      final s = await TrafficProfiler.I.stop();
      expect(TrafficProfiler.I.delete(s!.id), true);
      expect(TrafficProfiler.I.completed, isEmpty);
    });

    test('clearAll wipes completed', () async {
      for (var i = 0; i < 3; i++) {
        await TrafficProfiler.I.start('a$i');
        await TrafficProfiler.I.stop();
      }
      expect(TrafficProfiler.I.clearAll(), 3);
      expect(TrafficProfiler.I.completed, isEmpty);
    });
  });

  group('TrafficProfiler — log parsing', () {
    test('package detection populates conn-id map and DNS chain attribution',
        () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      // Pkg first, then CNAME, then A.
      TrafficProfiler.I.feedLogLineForTest(
          'INFO[0970] [3389974477 0ms] router: found package name: ru.tinkoff.investing');
      TrafficProfiler.I.feedLogLineForTest(
          'INFO[0970] [3389974477 16ms] dns: exchanged CNAME cdn.t-bank-app.ru. 17 IN CNAME cl-ead2c819.edgecdn.ru.');
      TrafficProfiler.I.feedLogLineForTest(
          'INFO[0970] [3389974477 17ms] dns: exchanged A cl-ead2c819.edgecdn.ru. 17 IN A 193.17.93.194');
      final session = TrafficProfiler.I.active!;
      // 1 dnsResolve event for the A record.
      final resolves = session.events
          .where((e) => e.kind == TrafficEventKind.dnsResolve)
          .toList();
      expect(resolves, hasLength(1));
      // event.domain атрибутируется на **исходный** запрошенный домен
      // (acc.domain — первое имя в conn-id accumulator), не на финальный
      // CNAME-target. CNAME hops собраны в cnameChain.
      expect(resolves.first.domain, 'cdn.t-bank-app.ru');
      expect(resolves.first.ip, '193.17.93.194');
      expect(resolves.first.cnameChain, ['cl-ead2c819.edgecdn.ru']);
      expect(resolves.first.process, 'ru.tinkoff.investing');
      // Aggregates: ключ — исходный domain.
      expect(session.byDomain.containsKey('cdn.t-bank-app.ru'), true);
    });

    test('non-target package events are ignored', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.feedLogLineForTest(
          'INFO[0970] [123 0ms] router: found package name: org.telegram.messenger');
      TrafficProfiler.I.feedLogLineForTest(
          'INFO[0970] [123 5ms] dns: exchanged A telegram.org. 60 IN A 1.2.3.4');
      expect(TrafficProfiler.I.active!.events, isEmpty);
    });

    test('DNS fail produces dnsTimeout issue', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.feedLogLineForTest(
          'INFO[0970] [777 0ms] router: found package name: ru.tinkoff.investing');
      TrafficProfiler.I.feedLogLineForTest(
          'INFO[0970] [777 5000ms] dns: exchange failed for some.host: context deadline exceeded');
      final ev = TrafficProfiler.I.active!.events.last;
      expect(ev.kind, TrafficEventKind.dnsFail);
      expect(ev.issues.first.kind, ConnectionIssueKind.dnsTimeout);
    });
  });

  group('TrafficProfiler — connection polling', () {
    test('new tcp conn for target → tcpOpen event (no issue on open)',
        () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.bindRuntime(connections: () async => {
            'connections': [
              {
                'id': 'c1',
                'metadata': {
                  'process': 'ru.tinkoff.investing',
                  'host': 'certs.t-bank-app.ru',
                  'destinationIP': '81.222.127.186',
                  'destinationPort': '443',
                  'network': 'tcp',
                },
                'chains': ['vless-server', '🇫🇮Финляндия (vpn-1)'],
                'upload': 0,
                'download': 0,
                'rule': 'default',
                'rulePayload': '',
              }
            ],
          });
      await TrafficProfiler.I.pollOnceForTest();
      final s = TrafficProfiler.I.active!;
      expect(s.events.length, 1);
      final ev = s.events.first;
      expect(ev.kind, TrafficEventKind.tcpOpen);
      expect(ev.domain, 'certs.t-bank-app.ru');
      expect(ev.ip, '81.222.127.186');
      // На open issues не вычисляем — оба текущих типа (dnsTimeout,
      // tcpReset) релевантны close/dns-fail event'ам.
      expect(ev.issues, isEmpty);
    });

    test('non-target connection ignored', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.bindRuntime(connections: () async => {
            'connections': [
              {
                'id': 'c2',
                'metadata': {
                  'process': 'org.telegram.messenger',
                  'host': 'tg.example',
                  'destinationIP': '5.5.5.5',
                  'destinationPort': '443',
                  'network': 'tcp',
                },
                'chains': ['direct'],
                'upload': 0,
                'download': 0,
              }
            ],
          });
      await TrafficProfiler.I.pollOnceForTest();
      expect(TrafficProfiler.I.active!.events, isEmpty);
    });

    test('closed connection emits tcpClose with duration', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      var snapshot = {
        'connections': [
          {
            'id': 'c3',
            'metadata': {
              'process': 'ru.tinkoff.investing',
              'host': 'cdn.t-bank-app.ru',
              'destinationIP': '193.17.93.194',
              'destinationPort': '443',
              'network': 'tcp',
            },
            'chains': ['direct-out'],
            'upload': 100,
            'download': 200,
          }
        ],
      };
      TrafficProfiler.I.bindRuntime(connections: () async => snapshot);
      await TrafficProfiler.I.pollOnceForTest();
      // Now drop it.
      snapshot = {'connections': []};
      await TrafficProfiler.I.pollOnceForTest();
      final s = TrafficProfiler.I.active!;
      expect(s.events.length, 2);
      expect(s.events.last.kind, TrafficEventKind.tcpClose);
      expect(s.events.last.duration, isNotNull);
    });

    test('TCP RST early flagged on close (closed <1s, 0 bytes)', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      var snapshot = {
        'connections': [
          {
            'id': 'rst',
            'metadata': {
              'process': 'ru.tinkoff.investing',
              'host': 'blocked.example',
              'destinationIP': '1.2.3.4',
              'destinationPort': '443',
              'network': 'tcp',
            },
            'chains': ['direct-out'],
            'upload': 0,
            'download': 0,
          }
        ],
      };
      TrafficProfiler.I.bindRuntime(connections: () async => snapshot);
      await TrafficProfiler.I.pollOnceForTest();
      // Close immediately (within 1s, 0 bytes).
      snapshot = {'connections': []};
      await TrafficProfiler.I.pollOnceForTest();
      final s = TrafficProfiler.I.active!;
      final closeEvent = s.events.last;
      expect(closeEvent.kind, TrafficEventKind.tcpClose);
      expect(
          closeEvent.issues.any((a) => a.kind == ConnectionIssueKind.tcpReset), true);
    });
  });

  group('TrafficProfiler — aggregates', () {
    test('byDomain sums bytes and counts connections', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.feedLogLineForTest(
          'INFO[0970] [111 0ms] router: found package name: ru.tinkoff.investing');
      TrafficProfiler.I.feedLogLineForTest(
          'INFO[0970] [111 5ms] dns: exchanged A api.tinkoff.ru. 60 IN A 1.1.1.1');
      TrafficProfiler.I.bindRuntime(connections: () async => {
            'connections': [
              {
                'id': 'c5',
                'metadata': {
                  'process': 'ru.tinkoff.investing',
                  'host': 'api.tinkoff.ru',
                  'destinationIP': '1.1.1.1',
                  'destinationPort': '443',
                  'network': 'tcp',
                },
                'chains': ['direct-out'],
                'upload': 1000,
                'download': 5000,
              }
            ],
          });
      await TrafficProfiler.I.pollOnceForTest();
      final s = TrafficProfiler.I.active!;
      final d = s.byDomain['api.tinkoff.ru']!;
      expect(d.connections, 1);
      expect(d.upBytes, 1000);
      expect(d.downBytes, 5000);
      expect(d.ips.contains('1.1.1.1'), true);
    });
  });

  group('TrafficProfiler — meta JSON', () {
    test('toMetaJson exposes counts', () async {
      final s = await TrafficProfiler.I.start('ru.tinkoff.investing');
      final j = s.toMetaJson();
      expect(j['target_package'], 'ru.tinkoff.investing');
      expect(j['session_id'], s.id);
      expect(j['events_count'], 0);
      expect(j['verbose'], false);
    });
  });
}
