// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/screens/node_settings_screen.dart';
import 'package:lxbox/services/settings_storage.dart';
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

// §728 — заметка «только TCP» в секции Info экрана узла: есть у http-прокси,
// нет у остальных протоколов.
void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('node_http_');
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

  const httpNode =
      '{"type":"http","tag":"local-http-out","server":"192.168.192.192","server_port":9201}';
  const vlessNode = 'vless://u1@h1.example:443?type=ws&security=tls#Alpha';
  const notice = ValueKey('http-tcp-only-notice');

  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await realIoStep(tester);
    }
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, String input) async {
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
    // Узел грузится после первого кадра: строка Protocol получает значение.
    await settle(tester, () => find.text('Protocol').evaluate().isNotEmpty);
  }

  testWidgets('у http-прокси под Server стоит заметка «только TCP»',
      (tester) async {
    await open(tester, httpNode);
    await settle(tester, () => find.byKey(notice).evaluate().isNotEmpty);
    expect(find.byKey(notice), findsOneWidget);
    expect(find.textContaining('only TCP connections'), findsOneWidget);
  });

  testWidgets('у узла другого протокола заметки нет', (tester) async {
    await open(tester, vlessNode);
    await settle(tester, () => find.text('vless').evaluate().isNotEmpty);
    expect(find.byKey(notice), findsNothing);
  });
}
