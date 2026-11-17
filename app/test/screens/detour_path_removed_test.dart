// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/folder_detail_screen.dart';
import 'package:lxbox/screens/node_settings_screen.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/tag_resolver.dart';
import 'package:lxbox/widgets/detour_path_line.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';
import 'real_io_pump.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

/// §752 — схема пути под выбором detour показывает итог последней сборки:
/// detour снят (`detour_unavailable`, §739) — путь перечёркнут и под ним
/// «идёт напрямую»; без кода — обычный вид; после пересборки вид
/// возвращается без перезахода. Выбор detour не трогается.
void main() {
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('detour_path_removed_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  RegistryWarning unavailable(String target, String tag) => RegistryWarning(
    code: 'detour_unavailable',
    params: {'target': target, 'count': '1', 'tags': tag},
    ownerTag: 'src',
  );

  const nodeDirect =
      'Not applied: the detour is unavailable, traffic goes directly to this server.';
  const nodesDirect =
      'Not applied: the detour is unavailable, nodes connect directly.';

  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await realIoStep(tester);
    }
    await tester.pumpAndSettle();
  }

  /// Путь нарисован перечёркнутым (true) или обычным (false).
  bool struck(WidgetTester tester) {
    final line = find.byType(DetourPathLine);
    final path = tester
        .widgetList<Text>(
          find.descendant(of: line, matching: find.byType(Text)),
        )
        .first;
    return path.style?.decoration == TextDecoration.lineThrough;
  }

  Future<void> rebuildWith(
    WidgetTester tester,
    SubscriptionController c,
    Map<String, List<NodeWarning>> byTag,
  ) async {
    c.debugSetLastBuildWarningsByTag(byTag);
    c.notifyListeners();
    await tester.pumpAndSettle();
  }

  testWidgets(
    'свой сервер: путь перечёркнут при снятом detour и возвращается',
    (tester) async {
      final c = SubscriptionController();
      await tester.runAsync(() async {
        await c.init();
        await c.addFromInput(
          'vless://u1@h1.example:443?type=ws&security=tls#Alpha',
        );
      });
      final entry = c.entries.single;
      entry.overrideDetour = const NodeLink(tag: 'vpn-2');
      final tag = TagResolver.displayTag(
        entry.list.tagPrefix,
        entry.list.nodes.first.tag,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: NodeSettingsScreen(entry: entry, index: 0, subController: c),
        ),
      );
      await settle(
        tester,
        () => find.byType(DetourPathLine).evaluate().isNotEmpty,
      );

      // До первой сборки — как раньше.
      expect(find.byType(DetourPathLine), findsOneWidget);
      expect(struck(tester), isFalse);
      expect(find.text(nodeDirect), findsNothing);

      await rebuildWith(tester, c, {
        tag: [unavailable('vpn-2', tag)],
      });
      expect(struck(tester), isTrue);
      expect(find.text(nodeDirect), findsOneWidget);
      expect(
        entry.overrideDetour,
        const NodeLink(tag: 'vpn-2'),
        reason: 'выбор detour не сбрасывается',
      );

      // Чужой код (другой узел) путь не трогает; пересборка без кода — обычный.
      await rebuildWith(tester, c, {
        'other': [unavailable('vpn-2', 'other')],
      });
      expect(struck(tester), isFalse);
      expect(find.text(nodeDirect), findsNothing);
    },
  );

  testWidgets('член папки с личным detour: тот же вид', (tester) async {
    final c = SubscriptionController();
    await tester.runAsync(() async {
      await c.init();
      await c.addFolder('F752');
      await c.addMembersToFolder(
        0,
        'vless://u1@h1.example:443?type=ws&security=tls#FA\n'
        'vless://u2@h2.example:443?type=ws&security=tls#FB',
      );
    });
    final entry = c.entries.single;
    final folder = entry.list as FolderServers;
    final ia = folder.members.indexWhere((m) => m.node?.tag == 'FA');
    await tester.runAsync(() async {
      final err = await c.setMemberDetour(
        0,
        ia,
        NodeLink(folderId: folder.id, tag: 'FB'),
      );
      expect(err, isNull);
    });
    final fa = (c.entries.single.list as FolderServers).members[ia].node!;
    final tag = TagResolver.displayTag(entry.list.tagPrefix, fa.tag);

    await tester.pumpWidget(
      MaterialApp(
        home: NodeSettingsScreen(
          entry: c.entries.single,
          index: 0,
          memberIndex: ia,
          subController: c,
        ),
      ),
    );
    await settle(
      tester,
      () => find.byType(DetourPathLine).evaluate().isNotEmpty,
    );
    expect(struck(tester), isFalse);

    await rebuildWith(tester, c, {
      tag: [unavailable('FB', tag)],
    });
    expect(struck(tester), isTrue);
    expect(find.text(nodeDirect), findsOneWidget);

    await rebuildWith(tester, c, const {});
    expect(struck(tester), isFalse);
    expect(find.text(nodeDirect), findsNothing);
  });

  testWidgets('detour папки на Settings: «узлы напрямую» при снятом detour', (
    tester,
  ) async {
    final c = SubscriptionController();
    await tester.runAsync(() async {
      await c.init();
      await c.addFolder('F752');
      await c.addMembersToFolder(
        0,
        'vless://u1@h1.example:443?type=ws&security=tls#FA',
      );
    });
    final entry = c.entries.single;
    entry.overrideDetour = const NodeLink(tag: 'vpn-2');
    entry.useDetourServers = true;
    final fa = (entry.list as FolderServers).members.single.node!;
    final tag = TagResolver.displayTag(entry.list.tagPrefix, fa.tag);

    await tester.pumpWidget(
      MaterialApp(
        home: FolderDetailScreen(entry: entry, controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.byType(DetourPathLine), findsOneWidget);
    expect(struck(tester), isFalse);

    await rebuildWith(tester, c, {
      tag: [unavailable('vpn-2', tag)],
    });
    expect(struck(tester), isTrue);
    expect(find.text(nodesDirect), findsOneWidget);

    await rebuildWith(tester, c, const {});
    expect(struck(tester), isFalse);
    expect(find.text(nodesDirect), findsNothing);
  });
}
