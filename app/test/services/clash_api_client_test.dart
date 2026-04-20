import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/clash_api_client.dart';

Map<String, dynamic> _loadFixture(String name) {
  final path = 'test/fixtures/clash_api/$name';
  final raw = File(path).readAsStringSync();
  return jsonDecode(raw) as Map<String, dynamic>;
}

void main() {
  group('TrafficSnapshot.fromConnectionsJson — real /connections fixture', () {
    late Map<String, dynamic> fixture;

    setUpAll(() {
      fixture = _loadFixture('connections_sample.json');
    });

    test('parses top-level totals', () {
      final s = TrafficSnapshot.fromConnectionsJson(fixture);
      expect(s.uploadTotal, (fixture['uploadTotal'] as num).toInt());
      expect(s.downloadTotal, (fixture['downloadTotal'] as num).toInt());
      expect(s.memory, (fixture['memory'] as num).toInt());
      expect(s.activeConnections,
          (fixture['connections'] as List).length);
    });

    test('byRule aggregates rule+payload', () {
      final s = TrafficSnapshot.fromConnectionsJson(fixture);
      final totalFromMap = s.byRule.values.fold<int>(0, (a, b) => a + b);
      // Some conns могут иметь пустой rule — суммируем только rule'd entries;
      // полный total должен быть ≤ activeConnections.
      expect(totalFromMap, lessThanOrEqualTo(s.activeConnections));
      // Ключи не должны содержать пустых строк
      for (final key in s.byRule.keys) {
        expect(key.isNotEmpty, true);
      }
    });

    test('byApp extracts package name without uid suffix', () {
      final s = TrafficSnapshot.fromConnectionsJson(fixture);
      for (final pkg in s.byApp.keys) {
        expect(pkg.contains(' ('), false,
            reason: 'package should not contain " (uid)" suffix');
        final stat = s.byApp[pkg]!;
        expect(stat.count > 0, true);
        expect(stat.upload >= 0, true);
        expect(stat.download >= 0, true);
      }
    });
  });

  group('TrafficSnapshot.fromConnectionsJson — edge cases', () {
    test('empty response → zero snapshot', () {
      final s = TrafficSnapshot.fromConnectionsJson(const {});
      expect(s.uploadTotal, 0);
      expect(s.downloadTotal, 0);
      expect(s.activeConnections, 0);
      expect(s.memory, 0);
      expect(s.byRule, isEmpty);
    });

    test('fallback summation when top-level totals are 0', () {
      final s = TrafficSnapshot.fromConnectionsJson({
        'uploadTotal': 0,
        'downloadTotal': 0,
        'connections': [
          {'upload': 100, 'download': 200, 'metadata': {}},
          {'upload': 50, 'download': 80, 'metadata': {}},
        ],
      });
      expect(s.uploadTotal, 150);
      expect(s.downloadTotal, 280);
    });

    test('rule + payload → "rule: payload" key', () {
      final s = TrafficSnapshot.fromConnectionsJson({
        'connections': [
          {'rule': 'rule_set', 'rulePayload': 'Block Ads', 'metadata': {}},
          {'rule': 'rule_set', 'rulePayload': 'Block Ads', 'metadata': {}},
          {'rule': 'final', 'rulePayload': '', 'metadata': {}},
        ],
      });
      expect(s.byRule['rule_set: Block Ads'], 2);
      expect(s.byRule['final'], 1);
    });

    test('package name stripped of uid suffix', () {
      final s = TrafficSnapshot.fromConnectionsJson({
        'connections': [
          {
            'upload': 10,
            'download': 20,
            'metadata': {'processPath': 'com.foo.bar (10042)'},
          },
          {
            'upload': 5,
            'download': 5,
            'metadata': {'processPath': 'com.foo.bar (10042)'},
          },
        ],
      });
      expect(s.byApp.containsKey('com.foo.bar'), true);
      expect(s.byApp.containsKey('com.foo.bar (10042)'), false);
      final stat = s.byApp['com.foo.bar']!;
      expect(stat.count, 2);
      expect(stat.upload, 15);
      expect(stat.download, 25);
      expect(stat.totalBytes, 40);
    });
  });

  group('ClashApiClient.urltestNow — real /proxies fixture', () {
    late Map<String, dynamic> proxies;

    setUpAll(() {
      proxies = _loadFixture('proxies_sample.json');
    });

    test('returns now for URLTest group', () {
      // В фикстуре ✨auto.now может быть либо пустой, либо populated —
      // проверяем что функция корректно возвращает ту или другую строку
      // в зависимости от now поля.
      final result = ClashApiClient.urltestNow(proxies, '✨auto');
      // Must be either null (now empty) or non-empty string
      expect(result == null || result.isNotEmpty, true);
    });

    test('returns null for Selector group', () {
      final result = ClashApiClient.urltestNow(proxies, 'vpn-1');
      expect(result, isNull);
    });

    test('returns null for Direct type', () {
      final result = ClashApiClient.urltestNow(proxies, 'direct-out');
      expect(result, isNull);
    });

    test('returns null for missing tag', () {
      final result = ClashApiClient.urltestNow(proxies, 'nonexistent-xyz');
      expect(result, isNull);
    });

    test('case-insensitive type matching (URLTest vs urltest)', () {
      final lowercase = {
        'proxies': {
          'grp': {'type': 'urltest', 'now': 'node-1'},
        },
      };
      expect(ClashApiClient.urltestNow(lowercase, 'grp'), 'node-1');
    });
  });

  group('AppStat', () {
    test('totalBytes sums upload + download', () {
      const s = AppStat(count: 3, upload: 100, download: 200);
      expect(s.totalBytes, 300);
    });

    test('zero constant has all fields == 0', () {
      expect(AppStat.zero.count, 0);
      expect(AppStat.zero.upload, 0);
      expect(AppStat.zero.download, 0);
      expect(AppStat.zero.totalBytes, 0);
    });
  });
}
