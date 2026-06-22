import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/automation/handlers.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';

/// §047 — extracted action-handlers. Проверяем precondition-валидацию, которую
/// handlers добавляют поверх контроллеров (она срабатывает до обращения к
/// HomeController, потому тестируется без живых контроллеров). Полная
/// бизнес-логика покрыта тестами самих контроллеров.
void main() {
  DebugContext emptyCtx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime(2026),
      );

  setUp(() {
    // DebugRegistry — синглтон (приватный конструктор). Гарантируем пустые
    // контроллеры, чтобы requireHome()/requireSub()/autoUpdater бросали.
    DebugRegistry.I.home = null;
    DebugRegistry.I.sub = null;
    DebugRegistry.I.autoUpdater = null;
  });

  group('input validation (до обращения к контроллеру)', () {
    test('switch-node: пустой tag → BadRequest', () {
      expect(
        () => actionSwitchNode('', emptyCtx()),
        throwsA(isA<BadRequest>()),
      );
    });

    test('set-group: пустой group → BadRequest', () {
      expect(
        () => actionSetGroup('', emptyCtx()),
        throwsA(isA<BadRequest>()),
      );
    });

    test('urltest-group: пустой group → BadRequest', () {
      expect(
        () => actionUrltestGroup('', emptyCtx()),
        throwsA(isA<BadRequest>()),
      );
    });
  });

  group('controller-not-ready preconditions', () {
    test('switch-node без home → Conflict', () {
      expect(
        () => actionSwitchNode('🇫🇮node', emptyCtx()),
        throwsA(isA<Conflict>()),
      );
    });

    test('set-group без home → Conflict', () {
      expect(
        () => actionSetGroup('grp', emptyCtx()),
        throwsA(isA<Conflict>()),
      );
    });

    test('reset-network без home → Conflict', () {
      expect(
        () => actionResetNetwork(emptyCtx()),
        throwsA(isA<Conflict>()),
      );
    });

    test('refresh-subs без autoUpdater → Conflict', () {
      expect(
        () => actionRefreshSubs(false, emptyCtx()),
        throwsA(isA<Conflict>()),
      );
    });

    test('urltest-group без home → Conflict', () {
      expect(
        () => actionUrltestGroup('grp', emptyCtx()),
        throwsA(isA<Conflict>()),
      );
    });
  });
}
