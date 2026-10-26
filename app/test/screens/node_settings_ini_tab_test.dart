// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/screens/node_settings_screen.dart';
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

const _priv = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=';
const _pub = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=';

// §686 п. 9 — вкладка INI у WireGuard/AmneziaWG: есть у WG, нет у VLESS;
// Edit INI у INI-источника — переход в Source, у ссылки — диалог и замена.
void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('node_ini_tab_');
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

  const awgLink = 'awg://$_priv@h.example:51820'
      '?publickey=$_pub&address=10.0.0.2/32'
      '&jc=3&jmin=40&jmax=70&ip=quic&id=www.example.org&ib=firefox#Alpha';
  const ini = '[Interface]\n'
      'PrivateKey = $_priv\n'
      'Address = 10.0.0.2/32\n'
      '\n'
      '[Peer]\n'
      'PublicKey = $_pub\n'
      'Endpoint = h.example:51820\n';

  /// Ждать условие, давая реальному IO (файлы, изоляты) идти.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
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

  Finder tab(String label) =>
      find.descendant(of: find.byType(TabBar), matching: find.text(label));
  int tabIndex(WidgetTester tester) =>
      tester.widget<TabBar>(find.byType(TabBar)).controller!.index;
  String rawOf(SubscriptionController c) =>
      (c.entries.single.list as UserServer).rawBody;

  Future<void> tapEditIni(WidgetTester tester) async {
    await tester.tap(tab('INI'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Edit INI'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit INI'));
    await tester.pumpAndSettle();
  }

  testWidgets('вкладка INI есть у WG, стоит после JSON', (tester) async {
    await open(tester, awgLink);
    final labels = tester
        .widget<TabBar>(find.byType(TabBar))
        .tabs
        .map((t) => t is Tab ? t.text : null)
        .toList();
    expect(labels.indexOf('INI'), labels.indexOf('JSON') + 1);
  });

  testWidgets('вкладки INI нет у VLESS', (tester) async {
    await open(tester, 'vless://u1@h1.example:443?type=ws&security=tls#Beta');
    expect(tab('INI'), findsNothing);
  });

  testWidgets('Edit INI у INI-источника — переход в Source без диалога',
      (tester) async {
    final c = await open(tester, ini);
    final before = rawOf(c);
    await tapEditIni(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tabIndex(tester), 1);
    expect(rawOf(c), before);
  });

  testWidgets('Edit INI у ссылки — диалог, источник заменён INI, тег прежний',
      (tester) async {
    final c = await open(tester, awgLink);
    final tag = c.entries.single.list.nodes.single.tag;
    await tapEditIni(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Continue')));
    await settle(tester, () => tabIndex(tester) == 1);
    expect(originKindOf(rawOf(c)), 'wg_ini');
    expect(rawOf(c), contains('Ip = quic'));
    expect(c.entries.single.list.nodes.single.tag, tag);
    expect(tabIndex(tester), 1);
  });
}
