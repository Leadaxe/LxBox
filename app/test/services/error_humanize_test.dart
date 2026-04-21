import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/error_humanize.dart';

void main() {
  group('humanizeError (night T2-2)', () {
    test('SocketException → "No connection"', () {
      final msg = humanizeError(
        const SocketException('x', address: null),
      );
      expect(msg, contains('No connection'));
    });

    test('TimeoutException → timeout phrasing', () {
      final msg = humanizeError(TimeoutException('x'));
      expect(msg.toLowerCase(), contains('time'));
    });

    test('HttpException with 401 → access denied hint', () {
      final msg = humanizeError(const HttpException('HTTP 401 for http://x'));
      expect(msg, contains('Access denied'));
      expect(msg, contains('401'));
    });

    test('HttpException with 404 → removed hint', () {
      final msg = humanizeError(const HttpException('HTTP 404 for http://x'));
      expect(msg, contains('Not found'));
    });

    test('HttpException with 503 → server down hint', () {
      final msg = humanizeError(const HttpException('HTTP 503 for http://x'));
      expect(msg.toLowerCase(), contains('server error'));
    });

    test('FormatException → parse error', () {
      final msg = humanizeError(const FormatException('bad'));
      expect(msg, contains('parse'));
    });

    test('plain Exception → strips "Exception: " prefix', () {
      final msg = humanizeError(Exception('something went wrong'));
      expect(msg, 'something went wrong');
    });

    test('long message truncated to ≤140 chars', () {
      final long = 'a' * 300;
      final msg = humanizeError(Exception(long));
      expect(msg.length, lessThanOrEqualTo(140));
      expect(msg, endsWith('...'));
    });
  });
}
