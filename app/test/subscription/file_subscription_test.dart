// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/http_cache.dart';
import 'package:lxbox/services/subscription/input_helpers.dart';
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

/// §129 — файловая подписка (Вариант Б: снапшот в кэш) + транзакционная смена
/// источника (online↔file).
void main() {
  late Directory tempDir;

  // Два+ ноды → файловая; одна нода → обычная.
  const twoNodes = 'vless://uuid-1@h1.example:443?type=ws&security=tls#A1\n'
      'vless://uuid-2@h2.example:443?type=ws&security=tls#A2\n';
  const oneNode = 'vless://uuid-1@h1.example:443?type=ws&security=tls#Solo\n';
  const threeNodes = 'vless://u1@h1:443?type=ws&security=tls#B1\n'
      'vless://u2@h2:443?type=ws&security=tls#B2\n'
      'vless://u3@h3:443?type=ws&security=tls#B3\n';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('file_sub_');
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

  group('§129 addFileSubscription', () {
    test('> 1 ноды → файловая подписка (url=file:, снапшот в кэше)', () async {
      final c = SubscriptionController();
      await c.init();
      final ok = await c.addFileSubscription(twoNodes, 'my-servers.txt');
      expect(ok, isTrue);

      final list = c.entries.single.list as SubscriptionServers;
      expect(isFileSubscription(list.url), isTrue);
      expect(list.name, 'my-servers'); // имя файла без .txt
      expect(list.nodes, hasLength(2));
      // Снапшот тела лёг в HttpCache по ключу url.
      expect(await HttpCache.loadBody(list.url), twoNodes);
    });

    test('≤ 1 ноды → НЕ файловая (false, caller упадёт на addFromInput)',
        () async {
      final c = SubscriptionController();
      await c.init();
      final ok = await c.addFileSubscription(oneNode, 'solo.txt');
      expect(ok, isFalse);
      expect(c.entries, isEmpty); // ничего не создано
    });
  });

  group('§129 re-hydrate файловой из кэша', () {
    test('старт: ноды пусты → поднимаются из HttpCache по file:url', () async {
      const url = 'file:abc-uuid';
      await SettingsStorage.saveServerLists([
        SubscriptionServers(
          id: 's1',
          name: 'file sub',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          url: url,
          lastNodeCount: 2,
        ),
      ]);
      await HttpCache.save(url, twoNodes, const {});

      final c = SubscriptionController();
      await c.init();
      await c.rehydrationDone;

      expect(c.entries.single.list.nodes, hasLength(2));
    });
  });

  group('§129 fetch файловой = keep-previous (auto-update не портит)', () {
    test('updateAt файловой не читает файл, ноды из кэша остаются', () async {
      final c = SubscriptionController();
      await c.init();
      await c.addFileSubscription(twoNodes, 'f.txt');
      final before = c.entries.single.list.nodes.length;

      await c.updateAt(0); // file: → skip fetch, keep-previous
      expect(c.entries.single.list.nodes, hasLength(before));
    });
  });

  group('§129 updateSourceAt — транзакционная смена источника', () {
    test('file → online (успех): коммит + чистка старого file-кэша', () async {
      final c = SubscriptionController();
      c.httpClientForTesting =
          MockClient((req) async => http.Response(threeNodes, 200));
      await c.init();
      await c.addFileSubscription(twoNodes, 'f.txt');
      final oldUrl = (c.entries.single.list as SubscriptionServers).url;

      final err =
          await c.updateSourceAt(0, httpUrl: 'https://new.example/sub');
      expect(err, isEmpty);

      final list = c.entries.single.list as SubscriptionServers;
      expect(list.url, 'https://new.example/sub');
      expect(list.nodes, hasLength(3));
      // старый file-кэш вычищен.
      expect(await HttpCache.loadBody(oldUrl), isNull);
    });

    test('online → online (fetch fail): полный откат, старое живёт', () async {
      final c = SubscriptionController();
      // Первый источник — успешный кэш; смена — на падающий URL.
      c.httpClientForTesting =
          MockClient((req) async => http.Response('boom', 500));
      await SettingsStorage.saveServerLists([
        SubscriptionServers(
          id: 's1',
          name: 'orig',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          url: 'https://orig.example/sub',
          lastNodeCount: 2,
        ),
      ]);
      await HttpCache.save('https://orig.example/sub', twoNodes, const {});
      await c.init();
      await c.rehydrationDone;

      final err =
          await c.updateSourceAt(0, httpUrl: 'https://broken.example/sub');
      expect(err, isNotEmpty); // ошибка

      final list = c.entries.single.list as SubscriptionServers;
      // url НЕ сменился, ноды/кэш старого источника целы.
      expect(list.url, 'https://orig.example/sub');
      expect(list.nodes, hasLength(2));
      expect(await HttpCache.loadBody('https://orig.example/sub'), twoNodes);
    });

    test('online → file (успех): url=file:, снапшот в кэше', () async {
      final c = SubscriptionController();
      await SettingsStorage.saveServerLists([
        SubscriptionServers(
          id: 's1',
          name: 'orig',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          url: 'https://orig.example/sub',
          lastNodeCount: 2,
        ),
      ]);
      await HttpCache.save('https://orig.example/sub', twoNodes, const {});
      await c.init();
      await c.rehydrationDone;

      final err = await c.updateSourceAt(0, fileBody: threeNodes);
      expect(err, isEmpty);

      final list = c.entries.single.list as SubscriptionServers;
      expect(isFileSubscription(list.url), isTrue);
      expect(list.nodes, hasLength(3));
      expect(await HttpCache.loadBody(list.url), threeNodes);
      // старый http-кэш вычищен.
      expect(await HttpCache.loadBody('https://orig.example/sub'), isNull);
    });
  });
}
