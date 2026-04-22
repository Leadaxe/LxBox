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
}
