// ignore_for_file: depend_on_referenced_packages
@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/config_node.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/outbound_view_screen.dart';
import 'package:lxbox/services/contract/group_genus.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

/// §565 / задача 570 — выбор члена группы ручного рода: переключатель на
/// экране узла и хранение выбора у группы подписки (`group_defaults`).
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

NodeSpec _node(String name) => parseAll(decode(
        'vless://11111111-2222-3333-4444-555555555555@$name.example:443'
        '?security=none#$name'))
    .single;

void main() {
  late Directory tempDir;
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lxbox_570_');
    await Directory('${tempDir.path}/docs').create(recursive: true);
    await Directory('${tempDir.path}/support').create(recursive: true);
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    SettingsStorage.resetCacheForTesting();
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  (SubscriptionController, NodeSpec, NodeSpec, AutoSelectSpec) setup() {
    final a = _node('a');
    final b = _node('b');
    final g = AutoSelectSpec(
      id: 'g',
      tag: 'G',
      label: 'G',
      genus: GroupGenus.manual,
      manualDefault: 'a',
    );
    final sub = SubscriptionController();
    sub.debugSetEntries([
      SubscriptionEntry(
        list: SubscriptionServers(
          id: 's1',
          name: 'sub',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          url: 'https://example.com/sub',
          nodes: [a, b, g],
        ),
        nodeCount: 3,
      ),
    ]);
    // Финальные теги сборки: префикса нет, совпадают с сырыми.
    sub.debugSetLastEmittedTagMap({'G': g, 'a': a, 'b': b});
    return (sub, a, b, g);
  }

  test('выбор у группы подписки хранится и накладывается на сборку', () async {
    final (sub, _, _, _) = setup();
    expect(await sub.rememberGroupMember('G', 'b', live: false), isTrue);
    final list = sub.entries.single.list as SubscriptionServers;
    expect(list.groupDefaults, {'G': 'b'});
    final applied = list.withGroupDefaultsApplied();
    final group = applied.nodes.whereType<AutoSelectSpec>().single;
    expect(group.manualDefault, 'b');
    // Оригинал узла не тронут: разбор тела его перезапишет, выбор — нет.
    expect(list.nodes.whereType<AutoSelectSpec>().single.manualDefault, 'a');
  });

  test('живой выбор: состояние записано, конфиг ждёт пересборки на старте',
      () async {
    final (sub, _, _, _) = setup();
    await sub.rememberGroupMember('G', 'b', live: true);
    expect(sub.groupDefaultsPending, isTrue);
  });

  test('кодек записи: group_defaults туда и обратно', () {
    final (sub, _, _, _) = setup();
    final list = (sub.entries.single.list as SubscriptionServers)
        .copyWith(groupDefaults: {'G': 'b'});
    final rec = sourceToRecord(list);
    expect(rec['group_defaults'], {'G': 'b'});
    final back = sourceFromRecord(jsonDecode(jsonEncode(rec)));
    expect((back.value as SubscriptionServers).groupDefaults, {'G': 'b'});
    expect(back.unknownKeys, isEmpty);
  });

  testWidgets('экран узла: тап по кружку члена выбирает его (без туннеля)',
      (tester) async {
    final (sub, _, _, _) = setup();
    final home = HomeController();
    addTearDown(home.dispose);
    final config = ParsedConfig.parse(jsonEncode({
      'outbounds': [
        {'type': 'selector', 'tag': 'G', 'outbounds': ['a', 'b'], 'default': 'a'},
        {'type': 'vless', 'tag': 'a', 'server': 'a.example', 'server_port': 443},
        {'type': 'vless', 'tag': 'b', 'server': 'b.example', 'server_port': 443},
      ],
    }));
    await tester.pumpWidget(MaterialApp(
      home: OutboundViewScreen(
        tag: 'G',
        kind: 'selector',
        json: '{}',
        detourCount: 0,
        onCopy: (_) {},
        config: config,
        subController: sub,
        homeController: home,
      ),
    ));
    await tester.pumpAndSettle();
    final pickB = find.byKey(const ValueKey('member-select-b'));
    expect(pickB, findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(pickB);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect((sub.entries.single.list as SubscriptionServers).groupDefaults,
        {'G': 'b'});
    final icon = tester.widget<Icon>(find.descendant(
        of: pickB, matching: find.byType(Icon)));
    expect(icon.icon, Icons.radio_button_checked);
  });
}
