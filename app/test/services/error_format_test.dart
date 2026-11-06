import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/error_format.dart';

// §279 Phase 4 — форматтер возвращает UiMsg; тесты ассертят пиненный
// английский рендер (renderEn), инвариант «строки те же, что до миграции».
String fmt(Object e) => formatUserError(e).renderEn();

void main() {
  group('formatUserError (§041)', () {
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

    test('SocketException — osError.message', () {
      final e = SocketException(
        'Failed host lookup',
        osError: const OSError('Connection refused', 61),
      );
      expect(fmt(e), 'Connection refused');
    });

    test('Long Object.toString — truncate до 120 chars + …', () {
      final long = Exception('x' * 200);
      final out = fmt(long);
      expect(out.length, 118); // 117 + '…'
      expect(out.endsWith('…'), isTrue);
    });
  });
}
