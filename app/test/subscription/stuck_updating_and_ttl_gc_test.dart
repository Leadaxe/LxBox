// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/auto_updater.dart';
import 'package:lxbox/services/subscription/sources.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

/// §591 P15/P10 — witness gap closed (2026-09-30).
///
/// P15: «зависшая "updating" не блокирует подписку навсегда» — init sweep
/// (inProgress → failed, lastUpdateAttempt сохраняется для min-retry) и
/// дедуп «второй запрос не стартует, пока первый ещё идёт».
///
/// P10 (частично): «спящая отметка чистится ТОЛЬКО на успешном сетевом
/// обновлении» — failed fetch не трогает disabledHashes, даже если TTL уже
/// истёк; следующий успешный fetch чистит как обычно.
void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;

  const bodyA = 'vless://uuid-1@h1.example:443?type=ws&security=tls#A1\n'
      'vless://uuid-2@h2.example:443?type=ws&security=tls#A2\n';

  SubscriptionServers sub(
    String url, {
    bool enabled = true,
    UpdateStatus lastUpdateStatus = UpdateStatus.never,
    DateTime? lastUpdateAttempt,
    Map<String, DateTime> disabledHashes = const {},
    int updateIntervalHours = 24,
  }) =>
      SubscriptionServers(
        id: 's1',
        name: 's1',
        enabled: enabled,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: url,
        lastUpdateStatus: lastUpdateStatus,
        lastUpdateAttempt: lastUpdateAttempt,
        disabledHashes: disabledHashes,
        updateIntervalHours: updateIntervalHours,
      );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('stuck_updating_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    fetchBackoffsForTesting = const [Duration.zero, Duration.zero];
  });

  tearDown(() async {
    fetchBackoffsForTesting = null;
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  group('P15 — зависшая "updating" не блокирует подписку навсегда', () {
    test('init sweep: inProgress → failed, lastUpdateAttempt сохраняется '
        '(min-retry 15 мин считает от него)', () async {
      // Симулируем kill процесса посреди fetch'а: на диске остался
      // lastUpdateStatus=inProgress с недавним lastUpdateAttempt.
      final attemptAt = DateTime.now().subtract(const Duration(minutes: 5));
      await SettingsStorage.saveServerLists([
        sub('http://x/a',
            lastUpdateStatus: UpdateStatus.inProgress,
            lastUpdateAttempt: attemptAt),
      ]);

      final c = SubscriptionController();
      await c.init();
      await c.rehydrationDone;

      final list = c.entries.single.list as SubscriptionServers;
      expect(list.lastUpdateStatus, UpdateStatus.failed,
          reason: 'sweep на init обязан снять завис — иначе '
              '_fetchEntryByRef guard блокирует подписку навсегда');
      expect(list.lastUpdateAttempt, attemptAt,
          reason: 'попытка не стирается — на неё опирается min-retry 15 мин '
              'в AutoUpdater.shouldUpdatePure');

      // Прямое следствие: shouldUpdatePure видит недавнюю попытку (5 мин
      // назад < 15 мин) и НЕ запускает авто-обновление раньше времени —
      // окно считается от attemptAt, как и утверждает P15.
      final tooSoon = AutoUpdater.shouldUpdatePure(
        list: list,
        force: false,
        fails: 0,
        now: attemptAt.add(const Duration(minutes: 5)),
      );
      expect(tooSoon, isFalse,
          reason: 'min-retry окно считается от сохранённого lastUpdateAttempt');
    });

    test('повторный "update" во время идущего запроса не шлёт второй HTTP',
        () async {
      await SettingsStorage.saveServerLists([sub('http://x/a')]);
      final c = SubscriptionController();
      await c.init();
      await c.rehydrationDone;

      var requestCount = 0;
      final release = Completer<void>();
      c.httpClientForTesting = MockClient((req) async {
        requestCount++;
        await release.future;
        return http.Response(bodyA, 200);
      });

      final entry = c.entries.single;
      // Dart однопоточный: первый вызов синхронно ставит
      // lastUpdateStatus=inProgress ДО первого await внутри
      // _fetchEntryByRef, так что второй вызов (без await между ними)
      // гарантированно видит guard уже поднятым.
      final first = c.refreshEntry(entry); // не await — запрос ещё «в сети»
      final second = c.refreshEntry(entry); // дедуп-guard должен его срезать

      final secondResult = await second;
      expect(secondResult, isFalse,
          reason: 'второй refresh при уже идущем inProgress обязан вернуть '
              'false, не стартуя HTTP');

      // Ждём, пока первый вызов реально дойдёт до HTTP (persist —
      // настоящий файловый I/O, несколько микрозадач), затем отпускаем его.
      while (requestCount == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(requestCount, 1,
          reason: 'ровно один HTTP-запрос — второй нажатие "update" не '
              'породило параллельный fetch');
      release.complete();
      await first;
    });
  });

  group('P10 — спящая отметка чистится ТОЛЬКО на успешном сетевом обновлении',
      () {
    test('failed fetch не чистит просроченную отметку; следующий успех '
        'чистит как обычно', () async {
      // Отметка "B1" просрочена по TTL (interval=24ч → порог 72ч), узла
      // B1 в новом теле нет ни разу за оба прохода.
      final nowSecondPrecision = DateTime.fromMillisecondsSinceEpoch(
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) * 1000);
      final staleSince =
          nowSecondPrecision.subtract(const Duration(hours: 100));
      await SettingsStorage.saveServerLists([
        sub('http://x/a',
            disabledHashes: {'B1': staleSince}, updateIntervalHours: 24),
      ]);

      final c = SubscriptionController();
      await c.init();
      await c.rehydrationDone;

      // 1) Сетевая ошибка — просроченная отметка обязана остаться: fetch не
      // дал сигнала "нода точно ушла", GC на этом пути не должен запускаться.
      c.httpClientForTesting =
          MockClient((req) async => throw const SocketException('offline'));
      await c.refreshEntry(c.entries.single);

      var list = c.entries.single.list as SubscriptionServers;
      expect(list.disabledHashes.containsKey('B1'), isTrue,
          reason: 'failed fetch не источник истины о составе — GC должен '
              'промолчать, даже если TTL уже истёк');
      expect(list.disabledHashes['B1']!.isAtSameMomentAs(staleSince), isTrue,
          reason: 'метка lastSeen не должна двигаться на failed fetch');

      // 2) Успешный fetch (B1 по-прежнему отсутствует в теле) — теперь GC
      // обязан снять просроченную отметку.
      c.httpClientForTesting =
          MockClient((req) async => http.Response(bodyA, 200));
      await c.refreshEntry(c.entries.single);

      list = c.entries.single.list as SubscriptionServers;
      expect(list.disabledHashes.containsKey('B1'), isFalse,
          reason: 'успешный сетевой fetch — GC чистит просроченную '
              'отметку отсутствующего узла');
    });
  });
}
