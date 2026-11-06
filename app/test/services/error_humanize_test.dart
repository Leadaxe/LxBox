import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/error_humanize.dart';

// §279 Phase 4 — humanizeError возвращает UiMsg; тесты ассертят английский
// рендер (renderEn).
String hum(Object e) => humanizeError(e).renderEn();

void main() {
  group('humanizeError (night T2-2)', () {
    test('SocketException with host in message → "No connection to <host>"',
        () {
      // regression: DNS lookup failure обычно не даёт `e.address`, но host
      // есть в тексте "Failed host lookup: 'api.example.com'".
      const e = SocketException(
        "Failed host lookup: 'api.example.com'",
      );
      final msg = hum(e);
      expect(msg, contains('No connection to api.example.com'));
    });

    test('TimeoutException with duration → includes seconds', () {
      // regression: doc обещал "Timed out after N seconds" — раньше код
      // всегда отдавал generic, теперь подставляет duration.
      final msg = hum(
        TimeoutException('x', const Duration(seconds: 30)),
      );
      expect(msg, contains('30s'));
      expect(msg.toLowerCase(), contains('timed out'));
    });

    test('TimeoutException without duration → generic timeout phrasing', () {
      final msg = hum(TimeoutException('x'));
      expect(msg, isNot(contains('0s')));
      expect(msg.toLowerCase(), contains('timed out'));
    });

    test('HttpException with 401 → access denied hint', () {
      final msg = hum(const HttpException('HTTP 401 for http://x'));
      expect(msg, contains('Access denied'));
      expect(msg, contains('401'));
    });

    test('plain Exception → strips "Exception: " prefix', () {
      final msg = hum(Exception('something went wrong'));
      expect(msg, 'something went wrong');
    });

    test('long message truncated to ≤140 chars', () {
      final long = 'a' * 300;
      final msg = hum(Exception(long));
      expect(msg.length, lessThanOrEqualTo(140));
      expect(msg, endsWith('...'));
    });
  });
}
