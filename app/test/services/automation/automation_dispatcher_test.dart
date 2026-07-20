import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/automation/automation_dispatcher.dart';
import 'package:lxbox/services/debug/contract/errors.dart';

/// §290 — symmetric request-response: маппинг исключения handler'а в
/// `(code, message)` для outgoing VPN_ERROR. Контролируемые DebugError отдаём
/// как есть; произвольное исключение → generic (не утекает в broadcast).
void main() {
  group('automationErrorSignal', () {
    test('DebugError → его code/message', () {
      final s = automationErrorSignal(const Conflict('tunnel not connected'));
      expect(s.code, 'conflict');
      expect(s.message, 'tunnel not connected');
    });

    test('BadRequest → bad_request + текст', () {
      final s = automationErrorSignal(const BadRequest('"tag" empty'));
      expect(s.code, 'bad_request');
      expect(s.message, '"tag" empty');
    });

    test('NotFound → not_found + текст', () {
      final s = automationErrorSignal(NotFound('group not found: "ghost"'));
      expect(s.code, 'not_found');
      expect(s.message, 'group not found: "ghost"');
    });

    test('произвольное исключение → generic (детали не утекают)', () {
      // Напр. FormatException с путём файла/URL внутри — наружу не должен уйти.
      final s = automationErrorSignal(
          const FormatException('failed at /data/user/0/…/config.json'));
      expect(s.code, 'error');
      expect(s.message, 'internal error');
      expect(s.message, isNot(contains('config.json')));
    });
  });
}
