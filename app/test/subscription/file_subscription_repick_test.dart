// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/debug_entry.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/subscription_node_list.dart';
import 'package:lxbox/screens/subscriptions_screen/widgets/subscription_entry_subtitle.dart';
import 'package:lxbox/services/app_log.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/http_cache.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tempRoot);
  final String tempRoot;
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

SubscriptionServers _sub(String url, {int lastNodeCount = 0}) =>
    SubscriptionServers(
      id: 's1',
      name: 'From file',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      url: url,
      lastNodeCount: lastNodeCount,
      updateIntervalHours: -1,
    );

const _twoNodes = 'vless://uuid-1@h1.example:443?type=ws&security=tls#A1\n'
    'vless://uuid-2@h2.example:443?type=ws&security=tls#A2\n';

/// §734 (issue #219) — файловая подписка, чьего текста на устройстве нет
/// (восстановление из бэкапа, другой телефон, переустановка), не молчит:
/// строка списка, вкладка Nodes и Update просят выбрать файл заново.
void main() {
  setUpAll(loadEngineSections);

  group('признак fileNeedsRepick', () {
    late Directory tempDir;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tempDir = await Directory.systemTemp.createTemp('file_repick_');
      await Directory('${tempDir.path}/docs').create();
      await Directory('${tempDir.path}/support').create();
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
      SettingsStorage.resetCacheForTesting();
      AppLog.I.resetForTesting();
    });

    tearDown(() async {
      try {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      } on FileSystemException {
        // гонка удаления temp — не предмет теста
      }
    });

    Future<SubscriptionController> start(SubscriptionServers s) async {
      await SettingsStorage.saveServerLists([s]);
      final c = SubscriptionController();
      await c.init();
      await c.rehydrationDone;
      await c.ensureHydrated(c.entries.single);
      return c;
    }

    test('файловая без текста — признак есть, даже без last_node_count',
        () async {
      final c = await start(_sub('file:abc'));
      expect(c.entries.single.fileNeedsRepick, isTrue);
    });

    test('Update без текста — признак остаётся, в журнале warning с подсказкой',
        () async {
      final c = await start(_sub('file:abc', lastNodeCount: 2));
      await c.updateAt(0);
      final entry = c.entries.single;
      expect(entry.fileNeedsRepick, isTrue);
      expect(entry.list.nodes, isEmpty);
      final line = AppLog.I.entries.where((e) =>
          e.level == DebugLevel.warning &&
          e.message.contains('choose it again via Edit source'));
      expect(line, hasLength(1));
      expect(line.single.message, contains('"From file"'));
    });

    test('файловая с текстом — признака нет', () async {
      await HttpCache.save('file:abc', _twoNodes, const {});
      final c = await start(_sub('file:abc', lastNodeCount: 2));
      expect(c.entries.single.list.nodes, hasLength(2));
      expect(c.entries.single.fileNeedsRepick, isFalse);
    });

    test('онлайн-подписка без тела — признака нет (её узлы даст Update)',
        () async {
      final c = await start(_sub('https://example.com/sub', lastNodeCount: 2));
      final entry = c.entries.single;
      expect(entry.nodesNotLoaded, isTrue);
      expect(entry.fileNeedsRepick, isFalse);
    });

    testWidgets('строка списка: «Choose the file again»', (tester) async {
      final c = SubscriptionController();
      final entry = SubscriptionEntry(list: _sub('file:abc'))
        ..debugMarkBodyCacheMissing();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) =>
                buildSubscriptionEntrySubtitle(ctx, entry, c) ??
                const SizedBox.shrink(),
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('entry-file-repick')), findsOneWidget);
      expect(find.text('Choose the file again'), findsOneWidget);
    });
  });

  testWidgets('вкладка Nodes: объяснение и выбор файла вместо Update',
      (tester) async {
    var choose = 0;
    var updates = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SubscriptionNodeList(
          nodes: const [],
          loading: false,
          error: null,
          notLoaded: true,
          onUpdate: () => updates++,
          fileMissing: true,
          onChooseFile: () => choose++,
        ),
      ),
    ));
    expect(find.byKey(const ValueKey('nodes-file-missing')), findsOneWidget);
    expect(find.byKey(const ValueKey('nodes-not-loaded')), findsNothing);
    expect(find.textContaining('A backup keeps subscription settings'),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nodes-file-missing-choose')));
    expect(choose, 1);
    expect(updates, 0);
  });
}
