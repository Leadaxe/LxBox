// ignore_for_file: depend_on_referenced_packages
@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/config_node.dart';
import 'package:lxbox/screens/outbound_view_screen.dart';
import 'package:lxbox/services/selector_info.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/vpn/cc_channel.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// §258 — Route на экране узла: выбор селектора на пути сменился не с этого
/// экрана (Debug API, главная, reselect urltest) — Route перерисовывается.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lxbox_258_route_');
    await Directory('${tempDir.path}/docs').create(recursive: true);
    await Directory('${tempDir.path}/support').create(recursive: true);
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    SelectorInfo.I.resetForTesting();
  });

  tearDown(() async {
    SettingsStorage.resetCacheForTesting();
    SelectorInfo.I.resetForTesting();
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  CcGroup group(String selected) => CcGroup(
        tag: 'L',
        type: 'selector',
        selectable: true,
        selected: selected,
        isExpand: false,
        items: const [],
      );

  testWidgets('смена выбора в detour-селекторе перерисовывает Route',
      (tester) async {
    final home = HomeController();
    addTearDown(home.dispose);
    final config = ParsedConfig.parse(jsonEncode({
      'outbounds': [
        {'type': 'vless', 'tag': 'X', 'server': 'x.example',
          'server_port': 443, 'detour': 'L'},
        {'type': 'selector', 'tag': 'L', 'outbounds': ['nl', 'de']},
        {'type': 'vless', 'tag': 'nl', 'server': 'nl.example',
          'server_port': 443},
        {'type': 'vless', 'tag': 'de', 'server': 'de.example',
          'server_port': 443},
      ],
    }));
    SelectorInfo.I.setGroups({'L': 'nl'});
    home.debugSetCcGroups([group('nl')]);

    await tester.pumpWidget(MaterialApp(
      home: OutboundViewScreen(
        tag: 'X',
        kind: 'vless',
        json: '{}',
        detourCount: 1,
        onCopy: (_) {},
        config: config,
        subController: SubscriptionController(),
        homeController: home,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('nl'), findsOneWidget);
    expect(find.text('de'), findsNothing);

    // Переключение не с экрана: пуш групп от ядра с новым выбором.
    SelectorInfo.I.setGroups({'L': 'de'});
    home.debugSetCcGroups([group('de')]);
    await tester.pumpAndSettle();
    expect(find.text('de'), findsOneWidget);
    expect(find.text('nl'), findsNothing);
  });
}
