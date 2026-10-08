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

SubscriptionServers _sub({int lastNodeCount = 5}) => SubscriptionServers(
      id: 's1',
      name: 'Main',
      enabled: false,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      url: 'http://x/a',
      lastNodeCount: lastNodeCount,
    );

/// §615 — подписка без тела в `sub_cache/`: узлы «не загружены», а не
/// «отсутствуют».
void main() {
  setUpAll(loadEngineSections);

  group('регидрация без кэша', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nodes_not_loaded_');
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

    test('тела нет: признак в памяти и warning в AppLog с путём кэша',
        () async {
      await SettingsStorage.saveServerLists([_sub()]);
      final c = SubscriptionController();
      await c.init();
      await c.rehydrationDone;

      final entry = c.entries.single;
      expect(entry.list.nodes, isEmpty);
      expect(entry.nodesNotLoaded, isTrue);
      final line = AppLog.I.entries.where((e) =>
          e.level == DebugLevel.warning &&
          e.source == DebugSource.app &&
          e.message.contains('no cached body'));
      expect(line, hasLength(1));
      expect(line.single.message, contains('"Main"'));
      expect(line.single.message, contains('/sub_cache/'));
    });
  });

  group('UI', () {
    testWidgets('вкладка Nodes: подсказка и Update вместо «No nodes found»',
        (tester) async {
      var updates = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SubscriptionNodeList(
            nodes: const [],
            loading: false,
            error: null,
            notLoaded: true,
            onUpdate: () => updates++,
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('nodes-not-loaded')), findsOneWidget);
      expect(
          find.text('Nodes are not loaded. Update the subscription to see them'),
          findsOneWidget);
      expect(find.text('No nodes found'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('nodes-not-loaded-update')));
      expect(updates, 1);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SubscriptionNodeList(
            nodes: const [],
            loading: false,
            error: null,
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('nodes-not-loaded')), findsNothing);
      expect(find.text('No nodes found'), findsOneWidget);
    });

    testWidgets('строка списка: счётчик узлов серый, пока узлы не загружены',
        (tester) async {
      final c = SubscriptionController();
      final entry = SubscriptionEntry(list: _sub());

      Future<void> pump() => tester.pumpWidget(MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) =>
                    buildSubscriptionEntrySubtitle(context, entry, c) ??
                    const SizedBox.shrink(),
              ),
            ),
          ));

      await pump();
      expect(find.byKey(const ValueKey('entry-node-count-stale')), findsNothing);
      expect(find.text('5 nodes'), findsOneWidget);

      entry.debugMarkBodyCacheMissing();
      await pump();
      final stale = find.byKey(const ValueKey('entry-node-count-stale'));
      expect(stale, findsOneWidget);
      final context = tester.element(stale);
      expect(tester.widget<Text>(stale).style?.color,
          Theme.of(context).colorScheme.outline);
    });
  });
}
