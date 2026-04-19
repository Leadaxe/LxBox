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
  });
}
