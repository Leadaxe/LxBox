import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/per_app_trace_tab/widgets/aggregate_axis.dart';
import 'package:lxbox/screens/per_app_trace_tab/widgets/aggregated_view.dart';
import 'package:lxbox/services/traffic_profiler.dart';

// §160 — активные соединения в Aggregated = open − close по ключу.
void main() {
  final t0 = DateTime.utc(2026, 6, 22, 12, 0, 0);

  TrafficEvent ev(TrafficEventKind kind,
          {String? domain, String? ip, int sec = 0}) =>
      TrafficEvent(
        ts: t0.add(Duration(seconds: sec)),
        kind: kind,
        domain: domain,
        ip: ip,
        port: 443,
      );

  group('AggregatedView.activeByKey — domain axis', () {
    test('open без close → активен', () {
      final events = [ev(TrafficEventKind.tcpOpen, domain: 'a.com')];
      expect(AggregatedView.activeByKey(events, AggAxis.domain),
          {'a.com': 1});
    });

    test('open + close → 0 активных', () {
      final events = [
        ev(TrafficEventKind.tcpOpen, domain: 'a.com', sec: 0),
        ev(TrafficEventKind.tcpClose, domain: 'a.com', sec: 5),
      ];
      expect(AggregatedView.activeByKey(events, AggAxis.domain),
          {'a.com': 0});
    });

    test('3 open, 1 close → 2 активных', () {
      final events = [
        ev(TrafficEventKind.tcpOpen, domain: 'a.com', sec: 0),
        ev(TrafficEventKind.tcpOpen, domain: 'a.com', sec: 1),
        ev(TrafficEventKind.tcpOpen, domain: 'a.com', sec: 2),
        ev(TrafficEventKind.tcpClose, domain: 'a.com', sec: 3),
      ];
      expect(AggregatedView.activeByKey(events, AggAxis.domain),
          {'a.com': 2});
    });

    test('udpOpen тоже считается открытием', () {
      final events = [ev(TrafficEventKind.udpOpen, domain: 'a.com')];
      expect(AggregatedView.activeByKey(events, AggAxis.domain),
          {'a.com': 1});
    });

    test('close больше open → clamp до 0 (не отрицательно)', () {
      final events = [
        ev(TrafficEventKind.tcpOpen, domain: 'a.com', sec: 0),
        ev(TrafficEventKind.tcpClose, domain: 'a.com', sec: 1),
        ev(TrafficEventKind.tcpClose, domain: 'a.com', sec: 2),
      ];
      expect(AggregatedView.activeByKey(events, AggAxis.domain),
          {'a.com': 0});
    });

    test('dns-события игнорируются', () {
      final events = [
        ev(TrafficEventKind.dnsResolve, domain: 'a.com'),
        ev(TrafficEventKind.dnsFail, domain: 'a.com'),
      ];
      expect(AggregatedView.activeByKey(events, AggAxis.domain), isEmpty);
    });

    test('несколько ключей независимы', () {
      final events = [
        ev(TrafficEventKind.tcpOpen, domain: 'a.com'),
        ev(TrafficEventKind.tcpOpen, domain: 'b.com'),
        ev(TrafficEventKind.tcpClose, domain: 'b.com'),
      ];
      expect(AggregatedView.activeByKey(events, AggAxis.domain),
          {'a.com': 1, 'b.com': 0});
    });

    test('null/пустой domain пропускается', () {
      final events = [
        ev(TrafficEventKind.tcpOpen, domain: null, ip: '1.2.3.4'),
        ev(TrafficEventKind.tcpOpen, domain: ''),
      ];
      expect(AggregatedView.activeByKey(events, AggAxis.domain), isEmpty);
    });
  });

  group('AggregatedView.activeByKey — ip axis', () {
    test('open/close по ip', () {
      final events = [
        ev(TrafficEventKind.tcpOpen, ip: '1.2.3.4', sec: 0),
        ev(TrafficEventKind.tcpOpen, ip: '1.2.3.4', sec: 1),
        ev(TrafficEventKind.tcpClose, ip: '1.2.3.4', sec: 2),
      ];
      expect(AggregatedView.activeByKey(events, AggAxis.ip), {'1.2.3.4': 1});
    });
  });
}
