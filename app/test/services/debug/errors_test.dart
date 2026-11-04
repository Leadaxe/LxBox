import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/contract/errors.dart';

void main() {
  group('DebugError.toJson', () {
    test('форма — {error: {code, message}}', () {
      final json = const BadRequest('missing tag').toJson();
      expect(json, {
        'error': {'code': 'bad_request', 'message': 'missing tag'},
      });
    });
  });
}
