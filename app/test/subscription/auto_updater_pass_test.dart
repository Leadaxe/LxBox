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

/// §603 — проход AutoUpdater: один URL за проход запрашивается один раз
/// (§027F); повторный вызов во время идущего прохода сообщает, что пропущен.
void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;
  const url = 'https://same.example/sub';
  const body = 'vless://u1@h1.example:443?type=ws&security=tls#N1\n'
      'vless://u2@h2.example:443?type=ws&security=tls#N2\n';

  SubscriptionServers sub(String id, String u) => SubscriptionServers(
        id: id,
        name: id,
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: u,
        onUpdateAction: SubscriptionOnUpdateAction.none,
      );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('au_pass_');
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

  test('две подписки с одним URL → один запрос, узлы у обеих', () async {
    await SettingsStorage.saveServerLists([sub('a', url), sub('b', url)]);
    final c = SubscriptionController();
    var hits = 0;
    c.httpClientForTesting = MockClient((req) async {
      hits++;
      return http.Response(body, 200);
    });
    await c.init();
    await c.rehydrationDone;
    final updater = AutoUpdater(c);

    final ran = await updater.maybeUpdateAll(UpdateTrigger.manual, force: true);

    expect(ran, isTrue);
    expect(hits, 1, reason: 'второй записи того же URL хватает ответа первой');
    for (final e in c.entries) {
      final list = e.list as SubscriptionServers;
      expect(list.nodes, hasLength(2), reason: list.id);
      expect(list.lastUpdateStatus, UpdateStatus.ok, reason: list.id);
    }
  });

  test('первый фетч URL неудачен → вторая запись того же URL не идёт в сеть',
      () async {
    await SettingsStorage.saveServerLists([sub('a', url), sub('b', url)]);
    final c = SubscriptionController();
    var hits = 0;
    c.httpClientForTesting = MockClient((req) async {
      hits++;
      return http.Response('boom', 500);
    });
    await c.init();
    await c.rehydrationDone;

    await AutoUpdater(c).maybeUpdateAll(UpdateTrigger.manual, force: true);

    // 3 попытки ретрая одного фетча; второй фетч дал бы 6.
    expect(hits, 3);
  });

  test('вызов во время идущего прохода → false', () async {
    await SettingsStorage.saveServerLists([sub('a', url)]);
    final c = SubscriptionController();
    final started = Completer<void>();
    final release = Completer<void>();
    c.httpClientForTesting = MockClient((req) async {
      if (!started.isCompleted) started.complete();
      await release.future;
      return http.Response(body, 200);
    });
    await c.init();
    await c.rehydrationDone;
    final updater = AutoUpdater(c);

    final first = updater.maybeUpdateAll(UpdateTrigger.periodic, force: true);
    await started.future;
    final second =
        await updater.maybeUpdateAll(UpdateTrigger.manual, force: true);
    release.complete();

    expect(second, isFalse, reason: 'второй вызов ничего не обновил');
    expect(await first, isTrue);
  });
}
