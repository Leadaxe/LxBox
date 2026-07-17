import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/error_format.dart';

// §279 Phase 4 — форматтер возвращает UiMsg; тесты ассертят пиненный
// английский рендер (renderEn), инвариант «строки те же, что до миграции».
String fmt(Object e) => formatUserError(e).renderEn();

void main() {
  group('formatUserError (§041)', () {
    test('TimeoutException — duration formatted as Ns', () {
      expect(fmt(TimeoutException('x', const Duration(seconds: 10))),
          'timeout 10s');
      expect(fmt(TimeoutException('x', const Duration(seconds: 5, milliseconds: 800))),
          'timeout 5.8s');
      expect(fmt(TimeoutException('x', const Duration(milliseconds: 500))),
          'timeout 0.5s');
    });

    test('TimeoutException — null duration → 0s', () {
      expect(fmt(TimeoutException('x')), 'timeout 0s');
    });

    test('FileSystemException — берём osError.message если есть', () {
      final e = FileSystemException(
        'Cannot open file',
        '/some/path',
        const OSError('No such file or directory', 2),
      );
      expect(fmt(e), 'No such file or directory');
    });

    test('FileSystemException — fallback на message без osError', () {
      final e = FileSystemException('Cannot open file', '/some/path');
      expect(fmt(e), 'Cannot open file');
    });

    test('SocketException — osError.message', () {
      final e = SocketException(
        'Failed host lookup',
        osError: const OSError('Connection refused', 61),
      );
      expect(fmt(e), 'Connection refused');
    });

    test('FormatException — message без stack-debris', () {
      const e = FormatException('Unexpected character', '{...}', 5);
      expect(fmt(e), 'Unexpected character');
    });

    test('PlatformException — берём message если есть', () {
      final e = PlatformException(
        code: 'start_failed',
        message: 'vpn_service.prepare returned false',
      );
      expect(fmt(e), 'vpn_service.prepare returned false');
    });

    test('PlatformException — fallback на code если message пустой', () {
      final e = PlatformException(code: 'unknown');
      expect(fmt(e), 'platform error: unknown');
    });

    test('Generic Exception — strip "Exception: " prefix', () {
      expect(fmt(Exception('something broke')), 'something broke');
    });

    test('Long Object.toString — truncate до 120 chars + …', () {
      final long = Exception('x' * 200);
      final out = fmt(long);
      expect(out.length, 118); // 117 + '…'
      expect(out.endsWith('…'), isTrue);
    });

    test('Short fallback — without truncation', () {
      expect(fmt(StateError('bad state')),
          'Bad state: bad state');
    });
  });
}
