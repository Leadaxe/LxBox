import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/stop_reason.dart';

// §279 Phase 0 — разбор строкового native-протокола stop-событий в typed
// StopReason. Инвариант миграции: message() воспроизводит дословно те же
// English-строки, что собирались в HomeController до §279.
void main() {
  group('StopReason.fromEvent', () {
    test('revoked → StopRevoked (errorReason игнорируется)', () {
      final r = StopReason.fromEvent(revoked: true, errorReason: 'whatever');
      expect(r, isA<StopRevoked>());
      expect(
        r!.renderEn(),
        'Another VPN app took the system VPN slot (e.g. an always-on VPN). '
        'Start again to reconnect.',
      );
    });

    test('alert:permission_location:<perms> → typed payload + verbatim render',
        () {
      final r = StopReason.fromEvent(
        revoked: false,
        errorReason: 'alert:permission_location:fine,background',
      );
      expect(r, isA<StopPermissionLocation>());
      expect((r as StopPermissionLocation).permissions, 'fine,background');
      // Debug API lastStartError — та же строка, что до §279.
      expect(r.renderEn(),
          'Stopped: alert:permission_location:fine,background');
    });

    test('прочий errorReason → StopError passthrough', () {
      final r = StopReason.fromEvent(
          revoked: false, errorReason: 'create service: bind failed');
      expect(r, isA<StopError>());
      expect(r!.renderEn(), 'Stopped: create service: bind failed');
    });

    test('чистый user-stop (errorReason null) → null', () {
      expect(StopReason.fromEvent(revoked: false, errorReason: null), isNull);
    });
  });

  group('StopReason equality', () {
    test('по runtimeType + полям данных', () {
      expect(const StopError('x'), const StopError('x'));
      expect(const StopError('x') == const StopError('y'), isFalse);
      expect(const StopRevoked(), const StopRevoked());
      expect(
        const StopRevoked() == const StopError('x'),
        isFalse,
      );
    });
  });

  group('StopStartTimeout (§519)', () {
    test('НЕ разбирается из native-события — причина синтезируется нами', () {
      // Ядро/native при таймауте фазы `connecting` молчат: `errorReason`
      // пустой. Поэтому `fromEvent` эту причину не производит и не должен —
      // её ставит `HomeController._armTransientTimeout`.
      expect(StopReason.fromEvent(revoked: false, errorReason: null), isNull);
    });

    test('renderEn несёт порог и число endpoint\'ов', () {
      const r = StopStartTimeout(seconds: 95, endpoints: 8);
      final en = r.renderEn();
      expect(en, contains('95'));
      expect(en, contains('8'));
      expect(en, contains('Start timed out'));
    });

    test('равенство по обоим полям', () {
      expect(const StopStartTimeout(seconds: 95, endpoints: 8),
          const StopStartTimeout(seconds: 95, endpoints: 8));
      expect(
        const StopStartTimeout(seconds: 95, endpoints: 8) ==
            const StopStartTimeout(seconds: 95, endpoints: 4),
        isFalse,
      );
      expect(
        const StopStartTimeout(seconds: 95, endpoints: 8) ==
            const StopError('x'),
        isFalse,
      );
    });
  });
}
