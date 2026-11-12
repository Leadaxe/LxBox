// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_dialect.dart';
import 'package:lxbox/screens/node_settings_screen.dart';
import 'package:lxbox/screens/subscriptions_screen/widgets/subscription_entry_tile.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';
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

Map<String, dynamic> _vless(String tag, String host, String id,
        {String? dialerProxy}) =>
    {
      'tag': tag,
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': host,
            'port': 443,
            'users': [
              {'id': id, 'encryption': 'none'}
            ],
          }
        ],
      },
      'streamSettings': {
        'network': 'tcp',
        'security': 'none',
        'sockopt': ?(dialerProxy == null ? null : {'dialerProxy': dialerProxy}),
      },
    };

/// Xray-конфиг: владелец `main` звонит через звено `relay` (`dialerProxy`).
final _xrayChain = jsonEncode({
  'outbounds': [
    _vless('main', 'example-1.com', '11111111-2222-3333-4444-555555555555',
        dialerProxy: 'relay'),
    _vless('relay', 'example-2.com', '11111111-2222-3333-4444-555555555556'),
  ],
});

final _xraySingle = jsonEncode(
    _vless('solo', 'example-3.com', '11111111-2222-3333-4444-555555555557'));

// §722 D — запись из нескольких узлов (владелец + звено): строка списка
// «N nodes», аккордеон «Nodes in this source» на Settings, массив тел на JSON.
void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('node_record_nodes_');
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

  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await realIoStep(tester);
    }
    await tester.pumpAndSettle();
  }

  Future<SubscriptionController> open(WidgetTester tester, String input) async {
    final c = SubscriptionController();
    await tester.runAsync(() async {
      await c.init();
      await c.addFromInput(input);
    });
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => NodeSettingsScreen(
                entry: c.entries.single,
                index: 0,
                subController: c,
              ),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(
        tester, () => find.byType(TabBarView).evaluate().isNotEmpty);
    expect(find.byType(TabBarView), findsOneWidget);
    return c;
  }

  String rawOf(SubscriptionController c) =>
      (c.entries.single.list as UserServer).rawBody;

  testWidgets('два узла: аккордеон, переименование звена переписывает '
      'dialerProxy', (tester) async {
    final c = await open(tester, _xrayChain);
    expect((c.entries.single.list as UserServer).dialect, SourceDialect.xray);

    expect(find.text('Nodes in this source'), findsOneWidget);
    expect(find.byKey(const ValueKey('record-node-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('record-node-1')), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('record-node-1')),
            matching: find.text('relay')),
        findsOneWidget);
    // Свёрнуты: поля Tag не видны.
    expect(find.byKey(const ValueKey('record-node-tag-1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('record-node-1')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('record-node-tag-1')), 'hop2');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Save'));
    await settle(tester, () => rawOf(c).contains('hop2'));

    final doc = jsonDecode(rawOf(c)) as Map<String, dynamic>;
    final outbounds = (doc['outbounds'] as List).cast<Map<String, dynamic>>();
    // Тег владельца мог получить эмодзи при импорте (§722 `_autoEmoji`):
    // владелец — тот, у кого есть `sockopt`.
    final main = outbounds.firstWhere(
        (o) => (o['streamSettings'] as Map?)?['sockopt'] != null);
    expect(main['streamSettings']['sockopt']['dialerProxy'], 'hop2');
    expect(outbounds.any((o) => o['tag'] == 'hop2'), isTrue);
    expect(outbounds.any((o) => o['tag'] == 'relay'), isFalse);
  });

  testWidgets('два узла: вкладка JSON — массив из двух тел, Edit JSON снят',
      (tester) async {
    await open(tester, _xrayChain);
    await tester.tap(find.descendant(
        of: find.byType(TabBar), matching: find.text('JSON')));
    await tester.pumpAndSettle();

    final view = tester.widget<LxJsonView>(find.byType(LxJsonView));
    final parsed = jsonDecode(view.text);
    expect(parsed, isA<List>());
    expect((parsed as List).length, 2);
    expect(parsed.every((e) => e is Map), isTrue);
    // Подсказка под рамкой высотой 420 — за краем экрана теста; ListView
    // строит детей лениво, поэтому сначала докрутить. Без докрутки и
    // `findsNothing` у Edit JSON проходил бы впустую.
    final hint = find.byKey(const ValueKey('json-edit-source-hint'));
    await tester.scrollUntilVisible(hint, 200,
        scrollable: find
            .descendant(
                of: find.ancestor(
                    of: find.byType(LxJsonView), matching: find.byType(ListView)),
                matching: find.byType(Scrollable))
            .first);
    expect(hint, findsOneWidget);
    expect(find.text('Edit JSON'), findsNothing);
  });

  testWidgets('один узел: блока нет, JSON — объект', (tester) async {
    await open(tester, _xraySingle);
    expect(find.text('Nodes in this source'), findsNothing);
    expect(find.byKey(const ValueKey('record-node-0')), findsNothing);

    await tester.tap(find.descendant(
        of: find.byType(TabBar), matching: find.text('JSON')));
    await tester.pumpAndSettle();
    final view = tester.widget<LxJsonView>(find.byType(LxJsonView));
    expect(jsonDecode(view.text), isA<Map>());
  });

  testWidgets('строка списка: запись из двух узлов — «2 nodes»',
      (tester) async {
    final nodes = parseAll(decode(_xrayChain), own: true);
    expect(recordNodesOf(nodes).length, 2);
    final entry = SubscriptionEntry(
      list: UserServer(
        id: 'u1',
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: _xrayChain,
        dialect: SourceDialect.xray,
        nodes: nodes,
      ),
      nodeCount: nodes.length,
    );
    final sub = SubscriptionController()..debugSetEntries([entry]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SubscriptionEntryTile(
          entry: entry,
          subController: sub,
          dragIndex: 0,
          onToggle: () {},
          onLaunchUrl: (_) {},
          onLongPress: (_) {},
          onTap: (_) {},
        ),
      ),
    ));
    expect(find.textContaining('2 nodes'), findsOneWidget);
  });
}
