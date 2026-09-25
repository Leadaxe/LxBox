// ignore_for_file: depend_on_referenced_packages
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/screens/chain_edit_screen.dart';
import 'package:lxbox/screens/owner_navigation.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// §558 — ссылка на цепочку из окна узла (View-экран, detour-cycle sheet)
// ведёт в редактор цепочки. До §558 `openTagOwner` искал владельца только
// среди `entries`, цепочки там нет — срабатывал fallback «Source not found».

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(MaterialApp(
    home: Builder(builder: (c) {
      ctx = c;
      return const Scaffold();
    }),
  ));
  return ctx;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lxbox_558_');
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

  testWidgets('тег цепочки → редактор цепочки', (tester) async {
    final sub = SubscriptionController();
    final home = HomeController();
    addTearDown(home.dispose);
    final ctx = await _pumpHost(tester);
    var notFound = false;

    // Файловый I/O в fake-async зоне testWidgets не завершается — storage
    // трогаем только в runAsync.
    await tester.runAsync(() async {
      await SettingsStorage.addChain(tag: 'via-de');
      await SettingsStorage.updateChain(const SourceChain(
          tag: 'via-de',
          hops: [NodeLink(tag: 'home'), NodeLink(tag: 'de-exit')]));
      unawaited(openTagOwner(
        ctx,
        'via-de',
        subController: sub,
        homeController: home,
        directions: const [],
        onOwnerNotFound: () => notFound = true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(notFound, isFalse);
    expect(find.byType(ChainEditScreen), findsOneWidget);
  });

  testWidgets('тег, которого нет нигде → fallback вызывающего',
      (tester) async {
    final sub = SubscriptionController();
    final home = HomeController();
    addTearDown(home.dispose);
    final ctx = await _pumpHost(tester);
    var notFound = false;

    await openTagOwner(
      ctx,
      'nope',
      subController: sub,
      homeController: home,
      directions: const [],
      chains: const [SourceChain(tag: 'via-de')],
      onOwnerNotFound: () => notFound = true,
    );

    expect(notFound, isTrue);
    expect(find.byType(ChainEditScreen), findsNothing);
  });
}
