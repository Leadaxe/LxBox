// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/config_dirty_check.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/auto_updater.dart';
import 'package:lxbox/services/workspaces/workspace_controller.dart';

import '../parser/engine_test_setup.dart';

/// §515 — регресс форумного дефекта: после переключения пространства во всех
/// пространствах видна одна подписка — последняя обновлённая.
///
/// Корень: `_persist()` заменяет ВЕСЬ набор не-цепочек в `lxbox_settings.json`
/// составом вызывающего контроллера, без привязки к слоту. Контроллер прежнего
/// слота переживает переключение (пересоздание только ключом `HomeScreen`, а
/// асинхронные хвосты продолжают жить) и пишет свои подписки в сцену, которая
/// к этому моменту принадлежит НОВОМУ слоту. Ближайший `load`/`saveAs`
/// копирует испорченную сцену в папку слота — потеря закрепляется на диске.
///
/// Барьер: контроллер запоминает `WorkspaceController.generation` при
/// рождении, `_persist()` сверяет его первой строкой. Плюс `AutoUpdater.halt()`
/// прерывает идущий проход на штатном пути переключения.
void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе.
  setUpAll(loadEngineSections);

  late Directory docs;
  late Directory support;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final ws = WorkspaceController.I;

  const urlWifi = 'http://x/wifi';
  const urlCell = 'http://x/cell';
  const bodyWifi = 'vless://u1@h1.example:443?type=ws&security=tls#W1\n'
      'vless://u2@h2.example:443?type=ws&security=tls#W2\n';

  SubscriptionServers sub(String url) => SubscriptionServers(
        id: url.split('/').last,
        name: url.split('/').last,
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: url,
      );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    docs = await Directory.systemTemp.createTemp('lxbox_515_docs_');
    support = await Directory.systemTemp.createTemp('lxbox_515_support_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
        case 'getApplicationDocumentsPath':
          return docs.path;
        case 'getApplicationSupportDirectory':
        case 'getApplicationSupportPath':
          return support.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
    ConfigDirtyCheck.resetForTesting();
    await ws.refresh();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SettingsStorage.resetCacheForTesting();
    for (final d in [docs, support]) {
      try {
        if (d.existsSync()) await d.delete(recursive: true);
      } on FileSystemException {
        // AppLog пишет persistent-лог в docs async — race с delete.
      }
    }
  });

  /// URL'ы подписок, реально лежащие в сцене (`lxbox_settings.json`).
  Future<List<String>> sceneUrls() async {
    SettingsStorage.resetCacheForTesting();
    final lists = await SettingsStorage.getServerLists();
    return [for (final l in lists) if (l is SubscriptionServers) l.url];
  }

  /// Два слота: `Cell` с подпиской cell, `WiFi` с подпиской wifi. Сцена = WiFi.
  /// Возвращает контроллер слота WiFi (тот, что переживёт переключение).
  Future<SubscriptionController> setUpTwoSlots() async {
    await SettingsStorage.saveServerLists([sub(urlCell)]);
    await ws.saveAs('Cell');
    await SettingsStorage.saveServerLists([sub(urlWifi)]);
    await ws.saveAs('WiFi');
    final c = SubscriptionController();
    await c.init();
    await c.rehydrationDone;
    expect(c.entries.single.list.id, 'wifi');
    return c;
  }

  test('РЕГРЕСС (а): отложенный фетч старого контроллера не трогает новый слот',
      () async {
    final cWifi = await setUpTwoSlots();

    // Фетч встаёт на gate — как живой HTTP в момент переключения.
    final gate = Completer<void>();
    cWifi.httpClientForTesting = MockClient((req) async {
      await gate.future;
      return http.Response(bodyWifi, 200);
    });
    final flying = cWifi.refreshEntry(cWifi.entries.single);

    // Переключение на Cell: сцена уже принадлежит слоту Cell.
    await ws.load('Cell', stopVpn: () async => false);
    final cCell = SubscriptionController();
    await cCell.init();
    await cCell.rehydrationDone;
    expect(cCell.entries.single.list.id, 'cell',
        reason: 'новый контроллер читает подписку загруженного слота');

    // Отвечает HTTP прежнего слота.
    gate.complete();
    final changed = await flying;

    expect(changed, isFalse,
        reason: 'результат фетча прежнего слота отброшен целиком');
    expect(await sceneUrls(), [urlCell],
        reason: 'подписка слота Cell на месте, состав WiFi не записан');
  });

  test('РЕГРЕСС (а-фейл): провалившийся фетч старого контроллера тоже не пишет',
      () async {
    final cWifi = await setUpTwoSlots();

    // Путь `0 нод` (HTML-заглушка) — свой `_persist(keepDirtyFlag: true)`.
    final gate = Completer<void>();
    cWifi.httpClientForTesting = MockClient((req) async {
      await gate.future;
      return http.Response('<html>stub</html>', 200);
    });
    final flying = cWifi.refreshEntry(cWifi.entries.single);

    await ws.load('Cell', stopVpn: () async => false);
    gate.complete();
    await flying;

    expect(await sceneUrls(), [urlCell],
        reason: 'даже путь фейла не затирает слот');
  });

  test('РЕГРЕСС (б): toggleAt старого контроллера после переключения — no-op '
      'на диске', () async {
    final cWifi = await setUpTwoSlots();

    await ws.load('Cell', stopVpn: () async => false);
    await cWifi.toggleAt(0);

    expect(await sceneUrls(), [urlCell],
        reason: 'любая мутация прежнего контроллера не доезжает до диска');
  });

  test('РЕГРЕСС (б-dispose): disposed контроллер не пишет даже в своём '
      'поколении', () async {
    final c = await setUpTwoSlots();
    c.dispose();

    await c.toggleAt(0);

    final urls = await sceneUrls();
    expect(urls, [urlWifi], reason: 'сцена та же (поколение не менялось)');
    final lists = await SettingsStorage.getServerLists();
    expect(lists.single.enabled, isTrue,
        reason: 'toggle disposed-контроллера на диск не лёг');
  });

  test('контроллер ТЕКУЩЕГО поколения пишет как обычно', () async {
    await setUpTwoSlots();
    await ws.load('Cell', stopVpn: () async => false);
    final cCell = SubscriptionController();
    await cCell.init();
    await cCell.rehydrationDone;

    await cCell.toggleAt(0);

    final lists = await SettingsStorage.getServerLists();
    expect(lists.single.enabled, isFalse,
        reason: 'барьер не задевает законного владельца сцены');
  });

  group('§515 AutoUpdater.halt', () {
    test('РЕГРЕСС (в): halt прерывает идущий проход между подписками',
        () async {
      // Две подписки: между ними `perSubscriptionDelay`. halt приходит во
      // время первого фетча — вторая в сеть не уходит.
      await SettingsStorage.saveServerLists([sub(urlWifi), sub(urlCell)]);
      final c = SubscriptionController();
      await c.init();
      await c.rehydrationDone;
      final updater = AutoUpdater(c);

      final hit = <String>[];
      final firstStarted = Completer<void>();
      c.httpClientForTesting = MockClient((req) async {
        hit.add(req.url.toString());
        if (!firstStarted.isCompleted) firstStarted.complete();
        return http.Response(bodyWifi, 200);
      });

      final run = updater.maybeUpdateAll(UpdateTrigger.manual, force: true);
      await firstStarted.future;
      updater.halt();
      await run;

      expect(hit, hasLength(1),
          reason: 'вторая подписка прохода не дождалась — halt прервал');
      expect(updater.runningForTesting, isFalse);
    });

    test('после halt новые проходы не стартуют', () async {
      await SettingsStorage.saveServerLists([sub(urlWifi)]);
      final c = SubscriptionController();
      await c.init();
      await c.rehydrationDone;
      final updater = AutoUpdater(c);
      updater.halt();

      var hits = 0;
      c.httpClientForTesting = MockClient((req) async {
        hits++;
        return http.Response(bodyWifi, 200);
      });

      await updater.maybeUpdateAll(UpdateTrigger.resumed);
      await updater.maybeUpdateAll(UpdateTrigger.manual, force: true);

      expect(hits, 0, reason: 'halt закрывает и unawaited-триггеры из resumed');
    });
  });
}
