import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/screens/connections_screen.dart';
import 'package:lxbox/services/process_name.dart';
import 'package:lxbox/services/rule_name_resolver.dart';

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

  group('§165 RuleNameResolver — справочник c.rule → title', () {
    setUp(() => RuleNameResolver.I.clear());
    tearDown(() => RuleNameResolver.I.clear());

    CustomRuleInline rule(String name, {
      List<String> suffixes = const [],
      List<String> domains = const [],
      List<String> ssids = const [],
      List<String> bssids = const [],
    }) =>
        CustomRuleInline(
          name: name,
          enabled: true,
          domains: domains,
          domainSuffixes: suffixes,
          wifiSsids: ssids,
          wifiBssids: bssids,
          outbound: 'vpn-1',
        );

    test('матч по условиям → title (даже при обрезке списка ядром)', () {
      RuleNameResolver.I.setRules([
        rule('Home wifi',
            suffixes: ['a.com', 'b.com', 'c.com', 'd.com', 'e.com'],
            ssids: ['LexRouteRich2G', 'LexRouteRich5G']),
      ]);
      // Ядро обрезало suffix-список до 3+`...` — но префикс совпадает.
      expect(
        ruleName(
            'domain_suffix=[a.com b.com c.com...] wifi_ssid=[LexRouteRich2G LexRouteRich5G] => route(vpn-1)'),
        'Home wifi',
      );
    });

    test('нормализация: лишние пробелы/переносы не ломают матч', () {
      RuleNameResolver.I.setRules([
        rule('Block Ads', suffixes: ['ads.com', 'track.com']),
      ]);
      expect(
        ruleName('domain_suffix=[ads.com   track.com]\n => reject'),
        'Block Ads',
      );
    });

    test('правило не найдено → fallback final', () {
      RuleNameResolver.I.setRules([rule('Home wifi', suffixes: ['a.com'])]);
      expect(ruleName('domain=[unknown.xyz]'), isNot('Home wifi'));
      expect(ruleName('final'), 'final');
      expect(ruleName(''), 'final');
    });

    test('кэш: повторный c.rule → тот же результат (быстрый путь)', () {
      RuleNameResolver.I.setRules([rule('Warp', suffixes: ['warp.test'])]);
      const s = 'domain_suffix=warp.test => route(vpn-1)';
      final first = ruleName(s);
      final second = ruleName(s);
      expect(first, 'Warp');
      expect(second, 'Warp');
    });

    test('fallback rule_set=<tag> когда справочник пуст', () {
      // setRules не вызван (пустой справочник) → fallback на rule_set-тег.
      expect(ruleName('rule_set=SomeTag => route(vpn-1)'), 'SomeTag');
      expect(ruleName('rule_set=[ru-domains ru-services]'), 'ru-domains');
    });
  });
}
