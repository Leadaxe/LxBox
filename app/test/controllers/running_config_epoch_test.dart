import 'package:flutter_test/flutter_test.dart';

/// §311 — захват снапшота running-конфига: прямые триггеры + epoch-гейт.
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

    /// Копия `_captureRunningConfig`: прямой захват + ретрай (пока ядро не
    /// STARTED → null, либо пока отдаёт ещё не подменённый конфиг == staleRaw)
    /// + epoch-гейт.
    Future<void> ensure(Future<String?> Function() rpc,
        {int maxAttempts = 12, String? staleRaw}) async {
      if (fetching) return;
      fetching = true;
      final captured = epoch;
      try {
        for (var i = 0; i < maxAttempts; i++) {
          final raw = await rpc();
          if (captured != epoch) return; // ← гейт: ответ старого box'а
          if (raw != null && raw != staleRaw) {
            snapshot = raw;
            return;
          }
        }
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
      }, maxAttempts: 1);
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
      }, maxAttempts: 1);
      snapshot = invalidate();
      await inFlight;
      // Новая сессия запускает свой захват.
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

    /// Device-факт 26.07: снапшот залипал в null на всю сессию, когда захват
    /// висел на `_applyGroups` — при in-place reload groups-push может не прийти
    /// вовсе (CommandClient переживает reload, дерево групп то же, а groups-pull
    /// заводится только на переходе в connected, которого при reload нет —
    /// §049 F4). Отсюда ПРЯМОЙ триггер (connected + reloadVpn) с ретраем.
    test('РЕГРЕСС: после reload снапшот перезахватывается ретраями', () async {
      const stale = 'config-OLD';
      snapshot = stale;
      // reloadVpn: запоминаем прежний, сбрасываем, bump'аем.
      snapshot = invalidate();

      // Новый box ещё не STARTED — первая попытка null.
      var attempt = 0;
      Future<String?> rpc() async {
        attempt++;
        return attempt < 2 ? null : 'config-NEW';
      }

      await ensure(rpc, staleRaw: stale);

      expect(snapshot, 'config-NEW',
          reason: 'без ретраев снапшот залипал бы в null на всю сессию');
    });

    /// Device-факт 26.07 (вторая половина): `reloadVPN` — асинхронный
    /// broadcast, ядро сразу после него ещё STARTED со СТАРЫМ box'ом и честно
    /// отдаёт доreload'ный конфиг. Ретрай «по null» такой ответ НЕ отсеивает —
    /// поэтому ждём ответ, отличный от прежнего снапшота.
    test('РЕГРЕСС: доreload\'ный ответ ядра не принимается за новый', () async {
      const stale = 'config-OLD';
      snapshot = invalidate();

      var attempt = 0;
      Future<String?> rpc() async {
        attempt++;
        // Ядро ещё не подменило box: первые два ответа — прежний конфиг.
        return attempt < 3 ? stale : 'config-NEW';
      }

      await ensure(rpc, staleRaw: stale);

      expect(snapshot, 'config-NEW',
          reason: 'иначе в кеш залипал бы конфиг до reload\'а');
      expect(attempt, 3);
    });

    test('каждая инвалидация двигает epoch (сброс ⟺ bump)', () {
      expect(invalidate(), isNull);
      expect(invalidate(), isNull);
      expect(epoch, 2, reason: 'все 5 точек сброса обязаны идти через хелпер');
    });
  });
}
