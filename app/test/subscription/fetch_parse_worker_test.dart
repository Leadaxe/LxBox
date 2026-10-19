// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/controllers/subscription_controller/cache_rehydrate.dart';
import 'package:lxbox/models/debug_entry.dart';
import 'package:lxbox/models/import_rule.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/app_log.dart';
import 'package:lxbox/services/settings_storage.dart';
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

/// §652 C — разбор ответа источника подписки в отдельном isolate.
void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;

  const url = 'http://x/sub';
  const body = 'vless://uuid-1@h1.example:443?type=ws&security=tls#A1\n'
      'vless://uuid-2@h2.example:443?type=ws&security=tls#A2\n'
      'vless://uuid-3@h3.example:443?type=ws&security=tls#B3\n';

  ImportRule replaceServer(String pattern, String server) => ImportRule(
        conditions: [
          ImportRuleCondition(
              path: 'tag', op: ImportRuleOperator.contains, pattern: pattern),
        ],
        targetPath: 'server',
        replacement: server,
      );

  late List<FetchParseInput> inputs;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('fetch_parse_worker_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    inputs = [];
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  Future<SubscriptionController> boot(
      {List<ImportRule> rules = const []}) async {
    await SettingsStorage.saveServerLists([
      SubscriptionServers(
        id: 's',
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: url,
        importRules: rules,
      ),
    ]);
    final c = SubscriptionController();
    await c.init();
    await c.rehydrationDone;
    c.httpClientForTesting = MockClient((req) async => http.Response(body, 200,
        headers: {'profile-title': 'Remote title'}));
    return c;
  }

  Iterable<DebugEntry> workerFailures() => AppLog.I
      .entriesForSource(DebugSource.app)
      .where((e) => e.message.startsWith('Parse: worker failed'));

  test('C п.9 refresh: разбор в isolate, узлы/мета/правила как на main',
      () async {
    final viaWorker = await boot(rules: [replaceServer('A', 'patched.example')]);
    final failuresBefore = workerFailures().length;
    viaWorker.fetchParseWorkerForTesting = (input, env) {
      inputs.add(input);
      return parseFetchedInIsolate(input, env);
    };
    expect(await viaWorker.refreshEntry(viaWorker.entries.single), isTrue);
    expect(inputs.single.fetch.body, body, reason: 'тело ушло в воркер');
    expect(workerFailures().length, failuresBefore);

    final onMain = await boot(rules: [replaceServer('A', 'patched.example')]);
    onMain.fetchParseWorkerForTesting =
        (input, env) async => parseFetchedWithRules(input);
    // Кэш тела общий с первым прогоном: состав тот же, но refresh разбирает.
    await onMain.refreshEntry(onMain.entries.single);

    final a = viaWorker.entries.single.list as SubscriptionServers;
    final b = onMain.entries.single.list as SubscriptionServers;
    expect(a.nodes.map((n) => n.tag), b.nodes.map((n) => n.tag));
    expect(a.nodes.map((n) => n.patchedJson?['server']),
        ['patched.example', 'patched.example', null]);
    expect(a.nodes.map((n) => n.patchedJson?['server']),
        b.nodes.map((n) => n.patchedJson?['server']));
    expect(a.name, 'Remote title');
    expect(a.meta?.profileTitle, b.meta?.profileTitle);
    expect(a.lastNodeCount, 3);
  });

  test('C п.10 отказ воркера на refresh → узлы разбором на main, warning',
      () async {
    final c = await boot();
    c.fetchParseWorkerForTesting =
        (input, env) => Future.error(StateError('worker down'));

    expect(await c.refreshEntry(c.entries.single), isTrue);

    expect(c.entries.single.list.nodes, hasLength(3));
    expect(
      workerFailures().any((e) =>
          e.level == DebugLevel.warning && e.message.contains('worker down')),
      isTrue,
    );
  });

  test('C п.11 правила сменились во время разбора → узлы с новыми', () async {
    final c = await boot(rules: [replaceServer('A', 'old.example')]);
    final entry = c.entries.single;
    c.fetchParseWorkerForTesting = (input, env) async {
      // Пока воркер разбирает по снимку правил на старте, пользователь
      // правит вкладку Filters.
      entry.updateImportRules([replaceServer('B', 'new.example')]);
      return parseFetchedInIsolate(input, env);
    };

    await c.refreshEntry(entry);

    final nodes = entry.list.nodes;
    expect(nodes, hasLength(3));
    expect(nodes.map((n) => n.patchedJson?['server']),
        [null, null, 'new.example']);
  });
}
