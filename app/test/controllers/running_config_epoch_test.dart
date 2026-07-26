import 'package:flutter_test/flutter_test.dart';

/// §311 — epoch-гейт снапшота running-конфига.
///
/// Найдено ревью диффа §311: `tunnelUp` НЕ различает сессии ядра. In-place
/// reload идёт **без status-flap** (§049 F4 — ядро остаётся `Started`),
/// CommandServer его переживает, groups-стрим не гасится. Поэтому fetch,
/// стартовавший до/во время reload'а, отвечает конфигом СТАРОГО box'а и без
/// гейта закоммитил бы его ПОСЛЕ сброса; pre-check `runningConfigRaw != null`
/// затем заблокировал бы refetch — stale-снапшот управлял бы `activeModel` до
/// конца сессии (ровно класс бага §311).
///
/// Тест воспроизводит гонку на модели той же логики (сам `HomeController`
/// завязан на native-каналы и в юнит-тесте не поднимается).
void main() {
  group('§311 epoch-гейт', () {
    late int epoch;
    late String? snapshot;
    late bool fetching;

    setUp(() {
      epoch = 0;
      snapshot = null;
      fetching = false;
    });

    /// Копия `_invalidateRunningConfig`: bump + сброс одним движением.
    String? invalidate() {
      epoch++;
      return null;
    }

    /// Копия `_ensureRunningConfig` с искусственной задержкой RPC.
    Future<void> ensure(Future<String?> Function() rpc) async {
      if (fetching) return;
      if (snapshot != null) return;
      fetching = true;
      final captured = epoch;
      try {
        final raw = await rpc();
        if (captured != epoch) return; // ← гейт
        if (raw != null) snapshot = raw;
      } finally {
        fetching = false;
      }
    }

    test('обычный путь: снапшот коммитится', () async {
      await ensure(() async => 'config-A');
      expect(snapshot, 'config-A');
      expect(epoch, 0);
    });

    test('РЕГРЕСС: ответ старого box\'а не переживает reload', () async {
      // fetch стартовал до reload'а и отвечает конфигом старой сессии.
      final inFlight = ensure(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return 'config-OLD';
      });
      // reloadVpn: инвалидация посреди RPC (туннель остаётся connected!).
      snapshot = invalidate();
      await inFlight;

      expect(snapshot, isNull,
          reason: 'stale-конфиг старого box\'а не должен коммититься');
      expect(epoch, 1);
    });

    test('после инвалидации следующий fetch снова разрешён', () async {
      final inFlight = ensure(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return 'config-OLD';
      });
      snapshot = invalidate();
      await inFlight;
      // Следующий groups-push перезапрашивает — уже у новой сессии.
      await ensure(() async => 'config-NEW');
      expect(snapshot, 'config-NEW',
          reason: 'pre-check != null не должен залипать после дропа');
    });

    test('параллельные fetch\'и: guard пропускает один', () async {
      var calls = 0;
      Future<String?> rpc() async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return 'config-A';
      }

      await Future.wait([ensure(rpc), ensure(rpc), ensure(rpc)]);
      expect(calls, 1);
      expect(snapshot, 'config-A');
    });

    test('каждая инвалидация двигает epoch (сброс ⟺ bump)', () {
      expect(invalidate(), isNull);
      expect(invalidate(), isNull);
      expect(epoch, 2, reason: 'все 5 точек сброса обязаны идти через хелпер');
    });
  });
}
