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
  });
}
