import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/clash_api_client.dart';
import 'package:lxbox/services/error_format.dart';

void main() {
  group('formatUserError (§041)', () {
    test('TimeoutException — duration formatted as Ns', () {
      expect(formatUserError(TimeoutException('x', const Duration(seconds: 10))),
          'timeout 10s');
      expect(formatUserError(TimeoutException('x', const Duration(seconds: 5, milliseconds: 800))),
          'timeout 5.8s');
      expect(formatUserError(TimeoutException('x', const Duration(milliseconds: 500))),
          'timeout 0.5s');
    });

    test('TimeoutException — null duration → 0s', () {
      expect(formatUserError(TimeoutException('x')), 'timeout 0s');
    });

    test('FileSystemException — берём osError.message если есть', () {
      final e = FileSystemException(
        'Cannot open file',
        '/some/path',
        const OSError('No such file or directory', 2),
      );
      expect(formatUserError(e), 'No such file or directory');
    });

    test('FileSystemException — fallback на message без osError', () {
      final e = FileSystemException('Cannot open file', '/some/path');
      expect(formatUserError(e), 'Cannot open file');
    });

    test('SocketException — osError.message', () {
      final e = SocketException(
        'Failed host lookup',
        osError: const OSError('Connection refused', 61),
      );
      expect(formatUserError(e), 'Connection refused');
    });

    test('FormatException — message без stack-debris', () {
      const e = FormatException('Unexpected character', '{...}', 5);
      expect(formatUserError(e), 'Unexpected character');
    });

    test('ClashHttpException — HTTP <code>', () {
      expect(formatUserError(ClashHttpException(401, '...')), 'HTTP 401');
      expect(formatUserError(ClashHttpException(503, '')), 'HTTP 503');
    });

    test('PlatformException — берём message если есть', () {
      final e = PlatformException(
        code: 'start_failed',
        message: 'vpn_service.prepare returned false',
      );
      expect(formatUserError(e), 'vpn_service.prepare returned false');
    });

    test('PlatformException — fallback на code если message пустой', () {
      final e = PlatformException(code: 'unknown');
      expect(formatUserError(e), 'platform error: unknown');
    });

    test('Generic Exception — strip "Exception: " prefix', () {
      expect(formatUserError(Exception('something broke')), 'something broke');
    });

    test('Long Object.toString — truncate до 120 chars + …', () {
      final long = Exception('x' * 200);
      final out = formatUserError(long);
      expect(out.length, 118); // 117 + '…'
      expect(out.endsWith('…'), isTrue);
    });

    test('Short fallback — without truncation', () {
      expect(formatUserError(StateError('bad state')),
          'Bad state: bad state');
    });
  });
}
