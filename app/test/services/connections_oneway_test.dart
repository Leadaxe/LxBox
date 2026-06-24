import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/connections_screen.dart';
import 'package:lxbox/services/process_name.dart';

/// §153 — тесты эвристики `isOneWayStuck` (подсветка зависших соединений).
///
/// Фикстура `connections_oneway_live.json` — живой снимок `/connections`
/// с устройства (21.06.2026), где WhatsApp-сессия залипла с ↑517 ↓0.
void main() {
  // Базовое: TCP, давно, перекос вверх → залип.
  final base = DateTime.parse('2026-06-21T20:00:00Z');
  final old = base.subtract(const Duration(seconds: 30));

  group('isOneWayStuck — logic', () {
    test('TCP, age≥3s, up>0 down=0 → true (↑517 ↓0)', () {
      expect(
        isOneWayStuck(
            network: 'tcp',
            upload: 517,
            download: 0,
            startTime: old,
            closed: false,
            now: base),
        isTrue,
      );
    });

    test('TCP, age≥3s, up=0 down>0 → true', () {
      expect(
        isOneWayStuck(
            network: 'tcp',
            upload: 0,
            download: 9000,
            startTime: old,
            closed: false,
            now: base),
        isTrue,
      );
    });

    test('двусторонний → false', () {
      expect(
        isOneWayStuck(
            network: 'tcp',
            upload: 1055,
            download: 6934,
            startTime: old,
            closed: false,
            now: base),
        isFalse,
      );
    });

    test('перекос, но download=4 (не ноль) → false', () {
      expect(
        isOneWayStuck(
            network: 'tcp',
            upload: 763,
            download: 4,
            startTime: old,
            closed: false,
            now: base),
        isFalse,
      );
    });

    test('свежее (<3s) → false (handshake в процессе)', () {
      expect(
        isOneWayStuck(
            network: 'tcp',
            upload: 517,
            download: 0,
            startTime: base.subtract(const Duration(seconds: 2)),
            closed: false,
            now: base),
        isFalse,
      );
    });

    test('UDP однобокое → false (для UDP норма)', () {
      expect(
        isOneWayStuck(
            network: 'udp',
            upload: 7672,
            download: 0,
            startTime: old,
            closed: false,
            now: base),
        isFalse,
      );
    });

    test('закрытое → false', () {
      expect(
        isOneWayStuck(
            network: 'tcp',
            upload: 517,
            download: 0,
            startTime: old,
            closed: true,
            now: base),
        isFalse,
      );
    });

    test('нет start → false', () {
      expect(
        isOneWayStuck(
            network: 'tcp',
            upload: 517,
            download: 0,
            startTime: null,
            closed: false,
            now: base),
        isFalse,
      );
    });

    test('zero-zero → false', () {
      expect(
        isOneWayStuck(
            network: 'tcp',
            upload: 0,
            download: 0,
            startTime: old,
            closed: false,
            now: base),
        isFalse,
      );
    });
  });

  group('isOneWayStuck — live fixture', () {
    test('ловит ровно 1 залип (WhatsApp ec2 ↑517 ↓0)', () {
      final raw = File(
              'test/fixtures/clash_api/connections_oneway_live.json')
          .readAsStringSync();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final conns = (data['connections'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      // Снимок снят ~23:23 +03 = 20:23Z; на этот момент залип жил >60с.
      final now = DateTime.parse('2026-06-21T20:24:00Z');

      final pink = conns.where((c) {
        final m = c['metadata'] as Map<String, dynamic>? ?? {};
        return isOneWayStuck(
          network: m['network']?.toString() ?? '',
          upload: c['upload'] as int? ?? 0,
          download: c['download'] as int? ?? 0,
          startTime: DateTime.tryParse(c['start']?.toString() ?? ''),
          closed: false,
          now: now,
        );
      }).toList();

      expect(pink.length, 1);
      final m = pink.first['metadata'] as Map<String, dynamic>;
      expect(m['host'].toString(), contains('amazonaws'));
      expect(pink.first['upload'], 517);
      expect(pink.first['download'], 0);
    });
  });

  // §154 — извлечение чистого package name для резолва иконки.
  group('packageNameFromProcess', () {
    test('ядро-формат "pkg (pkg)" → чистый pkg', () {
      expect(
        packageNameFromProcess('com.google.android.youtube (com.google.android.youtube)'),
        'com.google.android.youtube',
      );
    });

    test('"pkg (user)" → pkg', () {
      expect(packageNameFromProcess('com.whatsapp (u0_a123)'), 'com.whatsapp');
    });

    test('голый pkg → как есть', () {
      expect(packageNameFromProcess('org.telegram.messenger'),
          'org.telegram.messenger');
    });

    test('абсолютный путь → "" (не Android pkg)', () {
      expect(packageNameFromProcess('/usr/bin/curl'), '');
    });

    test('без точки → "" (не package)', () {
      expect(packageNameFromProcess('sshd'), '');
    });

    test('пусто → ""', () {
      expect(packageNameFromProcess(''), '');
      expect(packageNameFromProcess('   '), '');
    });

    test('живая фикстура: все processPath дают валидный pkg', () {
      final raw = File(
              'test/fixtures/clash_api/connections_oneway_live.json')
          .readAsStringSync();
      final conns = ((jsonDecode(raw) as Map)['connections'] as List)
          .cast<Map<String, dynamic>>();
      for (final c in conns) {
        final m = c['metadata'] as Map<String, dynamic>? ?? {};
        final pp = m['processPath']?.toString() ?? '';
        if (pp.isEmpty) continue;
        final pkg = packageNameFromProcess(pp);
        expect(pkg, isNotEmpty, reason: 'processPath="$pp"');
        expect(pkg.contains(' '), isFalse);
        expect(pkg.contains('('), isFalse);
      }
    });
  });

  group('ruleName — чистое имя правила (§122)', () {
    test('rule_set=[...] → первый тег набора', () {
      expect(ruleName('rule_set=[ru-domains ru-services geoip-ru]'),
          'ru-domains');
      expect(ruleName('rule_set=[geosite-google]'), 'geosite-google');
    });

    test('type=value → значение', () {
      expect(ruleName('domain_suffix=google.com'), 'google.com');
      expect(ruleName('ip_cidr=[10.0.0.0/8]'), '10.0.0.0/8');
    });

    test('без `=` → строка как есть', () {
      expect(ruleName('direct'), 'direct');
      expect(ruleName('final'), 'final');
    });

    test('пустое значение после `=` → тип', () {
      expect(ruleName('protocol='), 'protocol');
    });

    test('пустая строка → пустая', () {
      expect(ruleName(''), '');
      expect(ruleName('   '), '');
    });

    test('запятая-разделитель в наборе → первый', () {
      expect(ruleName('rule_set=[a, b, c]'), 'a');
    });
  });
}
