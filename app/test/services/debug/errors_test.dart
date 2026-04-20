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

    test('status codes по типам', () {
      expect(const BadRequest('x').status, 400);
      expect(const Unauthorized().status, 401);
      expect(const InvalidHost().status, 403);
      expect(const NotFound('x').status, 404);
      expect(const Conflict('x').status, 409);
      expect(PayloadTooLarge(1024).status, 413);
      expect(const UpstreamError('x').status, 502);
      expect(const RequestTimeout().status, 504);
      expect(const InternalError('x').status, 500);
    });

    test('коды стабильные (API contract)', () {
      expect(const Unauthorized().code, 'unauthorized');
      expect(const InvalidHost().code, 'invalid_host');
      expect(const RequestTimeout().code, 'timeout');
      expect(PayloadTooLarge(1).code, 'payload_too_large');
    });
  });
}
