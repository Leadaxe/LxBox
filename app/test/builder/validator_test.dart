import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/validation.dart';
import 'package:lxbox/services/builder/validator.dart';

void main() {
  group('validateConfig', () {
    test('empty config → ok', () {
      final r = validateConfig(<String, dynamic>{});
      expect(r.isOk, true);
      expect(r.issues, isEmpty);
    });

    test('dangling outbound ref → fatal', () {
      final r = validateConfig({
        'outbounds': [
          {'tag': 'a', 'type': 'direct'}
        ],
        'route': {
          'rules': [
            {'domain': ['x.com'], 'outbound': 'nonexistent'},
          ],
        },
      });
      expect(r.hasFatal, true);
      expect(r.fatal.single, isA<DanglingOutboundRef>());
    });

    test('§084 H1 — dangling detour ref → fatal', () {
      final r = validateConfig({
        'outbounds': [
          {'tag': 'main', 'type': 'vless', 'detour': 'ghost'},
          {'tag': 'direct-out', 'type': 'direct'},
        ],
      });
      expect(r.hasFatal, true);
      expect(r.fatal.single, isA<DanglingDetourRef>());
    });

    test('§084 H1 — detour на существующий outbound → ok', () {
      final r = validateConfig({
        'outbounds': [
          {'tag': 'main', 'type': 'vless', 'detour': 'hop'},
          {'tag': 'hop', 'type': 'vless'},
        ],
      });
      expect(r.isOk, true);
    });

    test('§084 H1 — detour на endpoint (wireguard) → ok', () {
      final r = validateConfig({
        'outbounds': [
          {'tag': 'main', 'type': 'vless', 'detour': 'wg-1'},
        ],
        'endpoints': [
          {'tag': 'wg-1', 'type': 'wireguard'},
        ],
      });
      expect(r.isOk, true);
    });

    test('empty urltest → fatal', () {
      final r = validateConfig({
        'outbounds': [
          {'tag': 'auto', 'type': 'urltest', 'outbounds': []},
        ],
      });
      expect(r.fatal.single, isA<EmptyUrltestGroup>());
    });

    test('selector default not in options → fatal', () {
      final r = validateConfig({
        'outbounds': [
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['a', 'b'],
            'default': 'missing',
          },
          {'tag': 'a', 'type': 'direct'},
          {'tag': 'b', 'type': 'direct'},
        ],
      });
      expect(r.fatal.single, isA<InvalidDefault>());
    });

    test('valid endpoint tag satisfies rule ref', () {
      final r = validateConfig({
        'outbounds': [],
        'endpoints': [
          {'tag': 'wg-1', 'type': 'wireguard'},
        ],
        'route': {
          'rules': [
            {'domain': ['x.com'], 'outbound': 'wg-1'},
          ],
        },
      });
      expect(r.isOk, true);
    });

    // Edge cases (night T7-3)

    test('rule с action:reject без outbound-string → не ошибка', () {
      final r = validateConfig({
        'outbounds': [
          {'type': 'direct', 'tag': 'direct-out'},
        ],
        'route': {
          'rules': [
            {'domain': ['ads.com'], 'action': 'reject'},
          ],
        },
      });
      expect(r.isOk, true);
    });

    test('selector без default — ok', () {
      final r = validateConfig({
        'outbounds': [
          {'type': 'direct', 'tag': 'direct-out'},
          {
            'type': 'selector',
            'tag': 'group',
            'outbounds': ['direct-out'],
          },
        ],
      });
      expect(r.isOk, true);
    });

    test('urltest с outbounds — ok', () {
      final r = validateConfig({
        'outbounds': [
          {'type': 'direct', 'tag': 'a'},
          {
            'type': 'urltest',
            'tag': 'group',
            'outbounds': ['a'],
          },
        ],
      });
      expect(r.isOk, true);
    });

    test('несколько issue накапливаются в одном result', () {
      final r = validateConfig({
        'outbounds': [
          {'type': 'direct', 'tag': 'direct-out'},
          {
            'type': 'urltest',
            'tag': 'empty-group',
            'outbounds': <String>[],
          },
          {
            'type': 'selector',
            'tag': 'bad-sel',
            'outbounds': ['direct-out'],
            'default': 'missing-tag',
          },
        ],
        'route': {
          'rules': [
            {'domain': ['x'], 'outbound': 'ghost'},
          ],
        },
      });
      expect(r.isOk, false);
      expect(r.issues.length, 3);
      expect(r.issues.whereType<DanglingOutboundRef>().length, 1);
      expect(r.issues.whereType<EmptyUrltestGroup>().length, 1);
      expect(r.issues.whereType<InvalidDefault>().length, 1);
    });

    test('пустые outbounds + пустые rules → ok', () {
      expect(validateConfig({'outbounds': [], 'route': {'rules': []}}).isOk,
          true);
    });

    // §121 — DNS resolver refs.

    test('§121 — dns.final на отсутствующий сервер → fatal', () {
      final r = validateConfig({
        'dns': {
          'servers': [
            {'tag': 'cloudflare_udp', 'type': 'udp'},
          ],
          'final': 'yandex_dot', // исчез (пресет выключен)
        },
      });
      expect(r.hasFatal, true);
      expect(r.fatal.single, isA<DanglingDnsServerRef>());
    });

    test('§121 — default_domain_resolver на отсутствующий сервер → fatal', () {
      final r = validateConfig({
        'dns': {
          'servers': [
            {'tag': 'cloudflare_udp', 'type': 'udp'},
          ],
        },
        'route': {'default_domain_resolver': 'yandex_udp'},
      });
      expect(r.hasFatal, true);
      expect(r.fatal.single, isA<DanglingDnsServerRef>());
    });

    test('§121 — оба resolver-поля на существующие серверы → ok', () {
      final r = validateConfig({
        'dns': {
          'servers': [
            {'tag': 'local_dns_resolver', 'type': 'local'},
            {'tag': 'cloudflare_udp', 'type': 'udp'},
          ],
          'final': 'local_dns_resolver',
        },
        'route': {'default_domain_resolver': 'cloudflare_udp'},
      });
      expect(r.isOk, true);
    });

    test('§121 — пустой/отсутствующий resolver-ref → ok (не fatal)', () {
      // dns без final, route без default_domain_resolver — проверка скипается.
      final r = validateConfig({
        'dns': {
          'servers': [
            {'tag': 'cloudflare_udp', 'type': 'udp'},
          ],
        },
      });
      expect(r.isOk, true);
    });

    test('§121 — конфиг без dns-блока → проверка не срабатывает', () {
      final r = validateConfig({
        'outbounds': [
          {'tag': 'direct-out', 'type': 'direct'},
        ],
      });
      expect(r.isOk, true);
    });

    // §141 P1.8a — detour cycle detection.

    test('§141 — detour self-reference (A→A) → fatal DetourCycle', () {
      final r = validateConfig({
        'outbounds': [
          {'tag': 'a', 'type': 'vless', 'detour': 'a'},
        ],
      });
      expect(r.hasFatal, true);
      expect(r.fatal.single, isA<DetourCycle>());
    });

    test('§141 — detour 2-cycle (A→B→A) → fatal DetourCycle', () {
      final r = validateConfig({
        'outbounds': [
          {'tag': 'a', 'type': 'vless', 'detour': 'b'},
          {'tag': 'b', 'type': 'vless', 'detour': 'a'},
        ],
      });
      expect(r.hasFatal, true);
      expect(r.fatal.whereType<DetourCycle>().length, 1);
    });

    test('§141 — detour 3-cycle через endpoint (A→B→C→A) → fatal', () {
      final r = validateConfig({
        'outbounds': [
          {'tag': 'a', 'type': 'vless', 'detour': 'b'},
          {'tag': 'b', 'type': 'vless', 'detour': 'c'},
        ],
        'endpoints': [
          {'tag': 'c', 'type': 'wireguard', 'detour': 'a'},
        ],
      });
      expect(r.fatal.whereType<DetourCycle>().length, 1);
    });

    test('§141 — линейная detour-цепочка (A→B→C) без цикла → ok', () {
      final r = validateConfig({
        'outbounds': [
          {'tag': 'a', 'type': 'vless', 'detour': 'b'},
          {'tag': 'b', 'type': 'vless', 'detour': 'c'},
          {'tag': 'c', 'type': 'direct'},
        ],
      });
      expect(r.isOk, true);
    });

    test('§141 — «хвост» входит в цикл (A→B→C→B), репортится один cycle', () {
      final r = validateConfig({
        'outbounds': [
          {'tag': 'a', 'type': 'vless', 'detour': 'b'},
          {'tag': 'b', 'type': 'vless', 'detour': 'c'},
          {'tag': 'c', 'type': 'vless', 'detour': 'b'},
        ],
      });
      expect(r.fatal.whereType<DetourCycle>().length, 1);
    });

    // §141 P1.8b — non-string selector default.

    test('§141 — non-string selector default (число) → fatal InvalidDefault', () {
      final r = validateConfig({
        'outbounds': [
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['a'],
            'default': 123, // не строка-тег
          },
          {'tag': 'a', 'type': 'direct'},
        ],
      });
      expect(r.hasFatal, true);
      expect(r.fatal.single, isA<InvalidDefault>());
    });

    test('§141 — валидный строковый default в опциях → ok', () {
      final r = validateConfig({
        'outbounds': [
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['a'],
            'default': 'a',
          },
          {'tag': 'a', 'type': 'direct'},
        ],
      });
      expect(r.isOk, true);
    });
  });

  // §141 P0.1 — контракт FatalValidationException (бросается в
  // SubscriptionController._generate при hasFatal; ловится generateConfig →
  // humanizeError → _lastError; null возврат блокирует save).
  group('FatalValidationException', () {
    test('toString перечисляет сообщения issues, без "Exception:" префикса', () {
      final e = FatalValidationException([
        const DanglingOutboundRef('rules[0]', 'ghost'),
        const EmptyUrltestGroup('auto'),
      ]);
      final s = e.toString();
      // humanizeError обрезает ведущий "Exception:"/"Error:" — наш toString не
      // должен начинаться с такого префикса, иначе смысл потеряется.
      expect(s.startsWith('Exception'), isFalse);
      expect(s.startsWith('Error'), isFalse);
      expect(s, contains('2 issues'));
      expect(s, contains('ghost'));
      expect(s, contains('auto'));
    });

    test('toString для одного issue — единственное число', () {
      final e = FatalValidationException(
          [const InvalidDefault('vpn-1', 'missing')]);
      expect(e.toString(), startsWith('Config invalid: '));
      expect(e.toString(), isNot(contains('issues')));
    });
  });
}
