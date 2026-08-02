import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/subscription/auto_updater.dart';

SubscriptionServers _sub({
  bool enabled = true,
  DateTime? lastUpdated,
  DateTime? lastUpdateAttempt,
  int updateIntervalHours = 24,
}) =>
    SubscriptionServers(
      id: 'x',
      name: 'x',
      enabled: enabled,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      url: 'https://example.com/sub',
      lastUpdated: lastUpdated,
      lastUpdateAttempt: lastUpdateAttempt,
      updateIntervalHours: updateIntervalHours,
    );

void main() {
  final now = DateTime(2026, 4, 22, 12, 0, 0);

  group('AutoUpdater.shouldUpdatePure (night T4-1, spec §027)', () {
    test('disabled подписка → never update', () {
      expect(
        AutoUpdater.shouldUpdatePure(
          list: _sub(enabled: false),
          force: false,
          fails: 0,
          now: now,
        ),
        isFalse,
      );
    });

    test('§129 interval ≤ 0 → never auto (но force работает)', () {
      // -1 = «Don't auto-update», 0 = «Never (respect server)». Оба на
      // авто-триггере пропускаются, ручной Update (force) обновляет.
      for (final iv in [-1, 0]) {
        final s = _sub(updateIntervalHours: iv, lastUpdated: null);
        expect(
          AutoUpdater.shouldUpdatePure(
              list: s, force: false, fails: 0, now: now),
          isFalse,
          reason: 'interval=$iv авто-триггер должен пропустить',
        );
        expect(
          AutoUpdater.shouldUpdatePure(
              list: s, force: true, fails: 0, now: now),
          isTrue,
          reason: 'interval=$iv force должен обновить',
        );
      }
    });

    test('fails >= maxFailsPerSession без force → skip', () {
      expect(
        AutoUpdater.shouldUpdatePure(
          list: _sub(lastUpdated: null),
          force: false,
          fails: AutoUpdater.maxFailsPerSession,
          now: now,
        ),
        isFalse,
      );
    });

    test('fails >= max с force → true', () {
      expect(
        AutoUpdater.shouldUpdatePure(
          list: _sub(lastUpdated: null),
          force: true,
          fails: AutoUpdater.maxFailsPerSession + 10,
          now: now,
        ),
        isTrue,
      );
    });

    test('force=true всегда true (даже при недавнем lastUpdated)', () {
      expect(
        AutoUpdater.shouldUpdatePure(
          list: _sub(lastUpdated: now.subtract(const Duration(minutes: 1))),
          force: true,
          fails: 0,
          now: now,
        ),
        isTrue,
      );
    });

    test('lastUpdateAttempt недавнее (< 15 мин) + не force → skip min-retry', () {
      expect(
        AutoUpdater.shouldUpdatePure(
          list: _sub(
            lastUpdated: now.subtract(const Duration(days: 2)),
            lastUpdateAttempt: now.subtract(const Duration(minutes: 5)),
          ),
          force: false,
          fails: 0,
          now: now,
        ),
        isFalse,
      );
    });

    test('lastUpdateAttempt >= 15 мин + lastUpdated старое → true', () {
      expect(
        AutoUpdater.shouldUpdatePure(
          list: _sub(
            lastUpdated: now.subtract(const Duration(days: 2)),
            lastUpdateAttempt: now.subtract(const Duration(minutes: 20)),
          ),
          force: false,
          fails: 0,
          now: now,
        ),
        isTrue,
      );
    });

    test('lastUpdated == null → true (никогда не обновлялось)', () {
      expect(
        AutoUpdater.shouldUpdatePure(
          list: _sub(lastUpdated: null),
          force: false,
          fails: 0,
          now: now,
        ),
        isTrue,
      );
    });

    test('lastUpdated моложе updateIntervalHours → skip', () {
      expect(
        AutoUpdater.shouldUpdatePure(
          list: _sub(
            lastUpdated: now.subtract(const Duration(hours: 12)),
            updateIntervalHours: 24,
          ),
          force: false,
          fails: 0,
          now: now,
        ),
        isFalse,
      );
    });

    test('lastUpdated старше updateIntervalHours → true', () {
      expect(
        AutoUpdater.shouldUpdatePure(
          list: _sub(
            lastUpdated: now.subtract(const Duration(hours: 25)),
            updateIntervalHours: 24,
          ),
          force: false,
          fails: 0,
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('§337 — updateDisabled (обновлять выключенные подписки)', () {
    test('выключенная: без галки skip, с галкой обновляется', () {
      final list = _sub(enabled: false);
      expect(
        AutoUpdater.shouldUpdatePure(
            list: list, force: false, fails: 0, now: now),
        isFalse,
        reason: 'дефолт (галка не передана) = прежнее поведение',
      );
      expect(
        AutoUpdater.shouldUpdatePure(
            list: list,
            force: false,
            fails: 0,
            now: now,
            updateDisabled: true),
        isTrue,
      );
    });

    test('галка НЕ отменяет §129 interval ≤ 0 (файловые подписки)', () {
      expect(
        AutoUpdater.shouldUpdatePure(
          list: _sub(enabled: false, updateIntervalHours: -1),
          force: false,
          fails: 0,
          now: now,
          updateDisabled: true,
        ),
        isFalse,
      );
    });

    test('галка НЕ отменяет min-retry', () {
      expect(
        AutoUpdater.shouldUpdatePure(
          list: _sub(
            enabled: false,
            lastUpdateAttempt: now.subtract(const Duration(minutes: 5)),
          ),
          force: false,
          fails: 0,
          now: now,
          updateDisabled: true,
        ),
        isFalse,
      );
    });

    test('галка НЕ отменяет fail-cap', () {
      expect(
        AutoUpdater.shouldUpdatePure(
          list: _sub(enabled: false),
          force: false,
          fails: AutoUpdater.maxFailsPerSession,
          now: now,
          updateDisabled: true,
        ),
        isFalse,
      );
    });

    test('включённая подписка от галки не зависит', () {
      for (final flag in [false, true]) {
        expect(
          AutoUpdater.shouldUpdatePure(
            list: _sub(lastUpdated: now.subtract(const Duration(hours: 25))),
            force: false,
            fails: 0,
            now: now,
            updateDisabled: flag,
          ),
          isTrue,
        );
      }
    });

    test('force выключенную БЕЗ галки не размораживает', () {
      expect(
        AutoUpdater.shouldUpdatePure(
          list: _sub(enabled: false),
          force: true,
          fails: 0,
          now: now,
        ),
        isFalse,
      );
    });
  });
}
