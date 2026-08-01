// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/sources.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

/// §331 (ревью) — жизненный цикл `configDirty` в fetch-пути.
///
/// Дефект: `_persist()` поднимал флаг на ЛЮБУЮ запись, включая чистые
/// метаданные (пометка попытки, фейл-статус, consecutiveFails). Каждый
/// неудачный авто-фетч (провайдер лёг, авиарежим) давал синюю плашку
/// «Settings changed» раз в час — тот же класс жалобы, что и исходная §323,
/// только по пути фейла. Плюс гонка: restore-хак затирал реальную правку
/// юзера, сделанную во время fetch'а.
///
/// Инвариант после ревью: флаг поднимает РОВНО один persist фетч-пути —
/// успешный, с реально изменившимся составом. Всё остальное — keepDirtyFlag.
void main() {
  late Directory tempDir;

  const bodyA = 'vless://uuid-1@h1.example:443?type=ws&security=tls#A1\n'
      'vless://uuid-2@h2.example:443?type=ws&security=tls#A2\n';
  const bodyB = 'vless://uuid-3@h3.example:443?type=ws&security=tls#B1\n';

  SubscriptionServers sub(String url) => SubscriptionServers(
        id: 's1',
        name: 's1',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: url,
      );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('fetch_dirty_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    // Без реального сна между ретраями (см. rehydrate_race_test §101).
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

  Future<SubscriptionController> boot(String url) async {
    await SettingsStorage.saveServerLists([sub(url)]);
    final c = SubscriptionController();
    await c.init();
    await c.rehydrationDone;
    return c;
  }

  group('§331 фейлы фетча НЕ поднимают configDirty', () {
    test('РЕГРЕСС: network error → флаг остаётся false', () async {
      final c = await boot('http://x/a');
      c.configDirty = false;
      c.httpClientForTesting =
          MockClient((req) async => throw const SocketException('offline'));

      final changed = await c.refreshEntry(c.entries.single);

      expect(changed, isFalse);
      expect(c.configDirty, isFalse,
          reason: 'фейл пишет только метаданные — пересобирать не из чего');
      final list = c.entries.single.list as SubscriptionServers;
      expect(list.lastUpdateStatus, UpdateStatus.failed);
      expect(list.lastUpdateAttempt, isNotNull,
          reason: 'сама пометка попытки персистится по-прежнему');
    });

    test('РЕГРЕСС: 200 с мусорным телом (0 нод) → флаг остаётся false',
        () async {
      final c = await boot('http://x/a');
      c.configDirty = false;
      c.httpClientForTesting =
          MockClient((req) async => http.Response('<html>stub</html>', 200));

      final changed = await c.refreshEntry(c.entries.single);

      expect(changed, isFalse);
      expect(c.configDirty, isFalse);
    });

    test('фейл НЕ гасит уже стоявший флаг (чужие pending-изменения)',
        () async {
      final c = await boot('http://x/a');
      c.configDirty = true; // реальная правка до фетча
      c.httpClientForTesting =
          MockClient((req) async => throw const SocketException('offline'));

      await c.refreshEntry(c.entries.single);

      expect(c.configDirty, isTrue);
    });
  });

  group('§331 успех: флаг только при изменившемся составе', () {
    test('новый состав → dirty=true, refreshEntry → true', () async {
      final c = await boot('http://x/a');
      c.configDirty = false;
      c.httpClientForTesting =
          MockClient((req) async => http.Response(bodyA, 200));

      final changed = await c.refreshEntry(c.entries.single);

      expect(changed, isTrue);
      expect(c.configDirty, isTrue);
      expect(c.entries.single.list.nodes, hasLength(2));
    });

    test('тот же состав повторно → dirty остаётся false, refreshEntry → false',
        () async {
      final c = await boot('http://x/a');
      c.httpClientForTesting =
          MockClient((req) async => http.Response(bodyA, 200));
      await c.refreshEntry(c.entries.single); // первый — новый состав
      c.configDirty = false; // «применили»

      final changed = await c.refreshEntry(c.entries.single);

      expect(changed, isFalse);
      expect(c.configDirty, isFalse,
          reason: 'подписка вернула тот же список — плашке не с чего гореть');
    });

    test('РЕГРЕСС (гонка restore-хака): правка юзера ВО ВРЕМЯ fetch\'а '
        'переживает same-composition фетч', () async {
      final c = await boot('http://x/a');
      c.httpClientForTesting =
          MockClient((req) async => http.Response(bodyA, 200));
      await c.refreshEntry(c.entries.single);
      c.configDirty = false;

      // Правка юзера прилетает пока fetch в сети. Старый вариант запоминал
      // флаг ДО fetch'а (false) и «восстанавливал» его после — затирая эту
      // правку. Теперь метаданные-персисты флаг не трогают вовсе.
      c.httpClientForTesting = MockClient((req) async {
        c.configDirty = true; // конкурентная правка в окне сети
        return http.Response(bodyA, 200); // состав тот же
      });

      final changed = await c.refreshEntry(c.entries.single);

      expect(changed, isFalse);
      expect(c.configDirty, isTrue,
          reason: 'same-composition фетч не смеет гасить чужой флаг');
    });

    test('смена состава при уже стоявшем флаге → флаг остаётся true',
        () async {
      final c = await boot('http://x/a');
      c.httpClientForTesting =
          MockClient((req) async => http.Response(bodyA, 200));
      await c.refreshEntry(c.entries.single);
      // dirty уже true от первого фетча; второй меняет состав → true.
      c.httpClientForTesting =
          MockClient((req) async => http.Response(bodyB, 200));

      final changed = await c.refreshEntry(c.entries.single);

      expect(changed, isTrue);
      expect(c.configDirty, isTrue);
      expect(c.entries.single.list.nodes, hasLength(1));
    });
  });
}
