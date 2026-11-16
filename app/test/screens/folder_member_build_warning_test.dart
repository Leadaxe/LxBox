// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/folder_detail_screen.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warning_row.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/tag_resolver.dart';
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

/// §739 итер. 3 — ⚠ сборки (`detour_unavailable`) у строки члена папки:
/// видно, у какого сервера снят detour; строка уходит после пересборки.
void main() {
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('folder_build_warn_');
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

  const unavailable = RegistryWarning(
    code: 'detour_unavailable',
    params: {'target': 'FJ', 'count': '1', 'tags': 'FA'},
    ownerTag: 'F730',
  );

  testWidgets('⚠ сборки только у строки нужного члена, уходит после пересборки',
      (tester) async {
    final c = SubscriptionController();
    await tester.runAsync(() async {
      await c.init();
      await c.addFolder('F730');
      await c.addMembersToFolder(
          0,
          'vless://u1@h1.example:443?type=ws&security=tls#FA\n'
          'vless://u2@h2.example:443?type=ws&security=tls#FB');
    });
    final entry = c.entries.single;
    final fa = (entry.list as FolderServers).members
        .firstWhere((m) => m.node?.tag == 'FA')
        .node!;
    c.debugSetLastBuildWarningsByTag({
      TagResolver.displayTag(entry.list.tagPrefix, fa.tag): const [unavailable],
    });

    await tester.pumpWidget(MaterialApp(
      home: FolderDetailScreen(entry: entry, controller: c),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(NodeWarningRow), findsOneWidget);
    final row = tester.widget<NodeWarningRow>(find.byType(NodeWarningRow));
    expect(row.warnings, contains(unavailable));
    expect(
      find.descendant(
        of: find.ancestor(
            of: find.text('FA'), matching: find.byType(ListTile)),
        matching: find.byType(NodeWarningRow),
      ),
      findsOneWidget,
    );

    c.debugSetLastBuildWarningsByTag(const {});
    c.notifyListeners();
    await tester.pump();
    expect(find.byType(NodeWarningRow), findsNothing);
  });
}
