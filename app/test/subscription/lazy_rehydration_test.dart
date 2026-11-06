// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/controllers/subscription_controller/cache_rehydrate.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/debug_entry.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/app_log.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/http_cache.dart';
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

/// §652 — выключенные подписки регидрируются лениво, разбор кэша — в isolate.
void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;

  const urlA = 'http://x/a';
  const urlB = 'http://x/b';
  const bodyA = 'vless://uuid-1@h1.example:443?type=ws&security=tls#A1\n'
      'vless://uuid-2@h2.example:443?type=ws&security=tls#A2\n';
  const bodyB = 'vless://uuid-3@h3.example:443?type=ws&security=tls#B1\n';

  SubscriptionServers sub(
    String id,
    String url, {
    bool enabled = true,
    Map<String, DateTime> disabledHashes = const {},
    Map<String, List<StoredWarning>> nodeWarnings = const {},
  }) =>
      SubscriptionServers(
        id: id,
        name: id,
        enabled: enabled,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: url,
        lastNodeCount: 1,
        disabledHashes: disabledHashes,
        nodeWarnings: nodeWarnings,
      );

  /// Воркер-счётчик: тела, отданные на разбор, и настоящий isolate под ним.
  late List<String> parsedBodies;
  Future<CacheParseResult> countingWorker(
      CacheParseInput input, ParseEnvSnapshot env) {
    parsedBodies.add(input.body);
    return parseCachedBodyInIsolate(input, env);
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('lazy_rehydrate_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    parsedBodies = [];
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  /// Включённая A и выключенная B, тела обеих в кэше.
  Future<SubscriptionController> bootTwo() async {
    await SettingsStorage.saveServerLists([
      sub('sa', urlA),
      sub('sb', urlB, enabled: false),
    ]);
    await HttpCache.save(urlA, bodyA, const {});
    await HttpCache.save(urlB, bodyB, const {});
    final c = SubscriptionController()
      ..cacheParseWorkerForTesting = countingWorker;
    await c.init();
    await c.rehydrationDone;
    return c;
  }

  bool emitted(SubscriptionController c, String tag) =>
      c.lastEmittedTagMap.values.any((n) => n.tag == tag);

  test('п.1 старт: включённая разобрана, выключенная нет', () async {
    final c = await bootTwo();

    expect(c.entries[0].list.nodes, hasLength(2));
    expect(c.entries[1].list.nodes, isEmpty);
    expect(parsedBodies, [bodyA], reason: 'тело выключенной не разбиралось');
    expect(c.entries[1].nodesNotLoaded, isFalse,
        reason: 'отложенная регидрация — не «тела нет в кэше»');
    expect(
      AppLog.I
          .entriesForSource(DebugSource.app)
          .where((e) => e.message.contains('worker failed')),
      isEmpty,
      reason: 'разбор прошёл в isolate, без отката на main',
    );
  });

  test('п.2 toggleAt включает → узлы до notify, конфиг с ними, флаг снят',
      () async {
    final c = await bootTwo();
    final seen = <int>[];
    c.addListener(() => seen.add(c.entries[1].list.nodes.length));

    await c.toggleAt(1);

    expect(c.entries[1].enabled, isTrue);
    expect(seen, isNotEmpty);
    expect(seen.first, 1, reason: 'узлы появились до первого уведомления');

    final json = await c.generateConfig();
    expect(json, isNotNull);
    expect(emitted(c, 'B1'), isTrue);
    expect(c.configDirty, isFalse);
  });

  test('п.3 сеттер enabled (путь Debug API) + generateConfig → узлы в конфиге',
      () async {
    final c = await bootTwo();
    c.entries[1].enabled = true;
    await c.persistSources();

    final json = await c.generateConfig();

    expect(json, isNotNull);
    expect(c.entries[1].list.nodes, hasLength(1));
    expect(emitted(c, 'B1'), isTrue);
    expect(c.configDirty, isFalse);
  });

  test('п.4 refresh неразобранной выключенной сохраняет вердикт core_rejected',
      () async {
    final ids = sourceNodeIdentities(parseAll(decode(bodyB)));
    final id = ids.values.single;
    await SettingsStorage.saveServerLists([
      sub('sb', urlB,
          enabled: false,
          disabledHashes: {id: DateTime.now()},
          nodeWarnings: {
            id: [StoredWarning.coreRejected('parse encryption: bad')],
          }),
    ]);
    await HttpCache.save(urlB, bodyB, const {});
    final c = SubscriptionController();
    await c.init();
    await c.rehydrationDone;
    expect(c.entries.single.list.nodes, isEmpty);

    c.httpClientForTesting =
        MockClient((req) async => http.Response(bodyB, 200));
    expect(await c.refreshEntry(c.entries.single), isFalse,
        reason: 'тот же состав — не изменение');

    final list = c.entries.single.list as SubscriptionServers;
    expect(list.nodeWarnings[id]?.any((w) => w.isCoreRejected), isTrue);
    expect(list.disabledHashes.containsKey(id), isTrue);
  });

  test('п.5 два параллельных ensureHydrated → один разбор', () async {
    final c = await bootTwo();
    final entry = c.entries[1];

    await Future.wait([c.ensureHydrated(entry), c.ensureHydrated(entry)]);

    expect(entry.list.nodes, hasLength(1));
    expect(parsedBodies.where((b) => b == bodyB), hasLength(1));
    await c.ensureHydrated(entry);
    expect(parsedBodies.where((b) => b == bodyB), hasLength(1));
  });

  test('п.7 отказ воркера → узлы разбором на main, warning в логе', () async {
    await SettingsStorage.saveServerLists([sub('sa', urlA)]);
    await HttpCache.save(urlA, bodyA, const {});
    final c = SubscriptionController()
      ..cacheParseWorkerForTesting =
          (input, env) => Future.error(StateError('worker down'));
    await c.init();
    await c.rehydrationDone;

    expect(c.entries.single.list.nodes, hasLength(2));
    expect(
      AppLog.I.entriesForSource(DebugSource.app).any((e) =>
          e.level == DebugLevel.warning &&
          e.message.contains('worker failed') &&
          e.message.contains('worker down')),
      isTrue,
    );
  });
}
