// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/config_node.dart';
import 'package:lxbox/screens/outbound_view_screen.dart';
import 'package:lxbox/services/diagnostics/diagnostic_check.dart';
import 'package:lxbox/services/platform_channels.dart';
import 'package:lxbox/services/selector_info.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/widgets/node_diagnostics_tab.dart';
import 'package:lxbox/widgets/path_mtu_island.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../services/path_mtu_test.dart' show FakeProber;

/// §725 — остров Path MTU, комбобокс Endpoint в острове Check, остров только
/// у узла direct.
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
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('остров Path MTU', () {
    String? clipboard;

    setUp(() {
      clipboard = null;
      messenger.setMockMethodCallHandler(SystemChannels.platform,
          (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
    });

    tearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    Future<void> pump(WidgetTester tester, FakeProber p) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(children: [PathMtuIsland(prober: p)]),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('MTU интерфейса виден до запуска', (tester) async {
      await pump(tester, FakeProber());
      expect(find.text('wlan0 (Wi-Fi) · MTU 1500'), findsOneWidget);
      expect(find.byKey(const ValueKey('path-mtu-value')), findsNothing);
    });

    testWidgets('итог, рекомендация, пробы, копирование', (tester) async {
      await pump(tester, FakeProber());
      await tester.tap(find.byKey(const ValueKey('path-mtu-run')));
      await tester.pumpAndSettle();

      expect(find.text('Path MTU 1340'), findsOneWidget);
      expect(find.byKey(const ValueKey('path-mtu-recommend')), findsOneWidget);
      expect(find.textContaining('1280'), findsWidgets);
      expect(find.textContaining('1289'), findsOneWidget);

      await tester.tap(find.textContaining('Probes ('));
      await tester.pumpAndSettle();
      expect(find.text('84 · ok 38 ms'), findsOneWidget);
      expect(find.text('1500 · no reply'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('path-mtu-copy')));
      await tester.pump();
      expect(clipboard, contains('Path MTU 1340'));
      expect(clipboard, contains('MASQUE ≤ 1289'));
      expect(clipboard, contains('1500 · no reply'));
    });

    testWidgets('цель не отвечает — без чисел и рекомендации',
        (tester) async {
      await pump(tester, FakeProber(threshold: 10));
      await tester.tap(find.byKey(const ValueKey('path-mtu-run')));
      await tester.pumpAndSettle();
      expect(find.text('Target does not answer ping'), findsOneWidget);
      expect(find.byKey(const ValueKey('path-mtu-value')), findsNothing);
      expect(find.byKey(const ValueKey('path-mtu-recommend')), findsNothing);
    });

    testWidgets('путь пропускает всё', (tester) async {
      await pump(tester, FakeProber(threshold: 9000));
      await tester.tap(find.byKey(const ValueKey('path-mtu-run')));
      await tester.pumpAndSettle();
      expect(find.text('Path MTU 1500'), findsOneWidget);
      expect(find.text('Nothing is cut on the way'), findsOneWidget);
    });

    testWidgets('нет сети', (tester) async {
      await pump(tester, FakeProber(noNetwork: true));
      expect(find.text('No network'), findsOneWidget);
    });
  });

  group('Endpoint в острове Check', () {
    const methods = MethodChannel(PlatformChannels.methods);
    late List<String> links;

    setUp(() {
      links = [];
      messenger.setMockMethodCallHandler(methods, (call) async {
        switch (call.method) {
          case 'getVpnStatus':
            return 'Started';
          case 'ccGetUrlViaOutbound':
            links.add((call.arguments as Map)['link'] as String);
            return {'status': 200, 'content': 'ok', 'error': ''};
        }
        return null;
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(methods, null));

    Future<void> pumpTab(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: NodeDiagnosticsTab(liveTag: 'X')),
      ));
      await tester.pumpAndSettle();
    }

    Finder field() => find.descendant(
        of: find.byKey(const ValueKey('diag-endpoint')),
        matching: find.byType(TextField));

    ButtonStyleButton runButton(WidgetTester tester) =>
        tester.widget<ButtonStyleButton>(
            find.byKey(const ValueKey('diag-run')));

    testWidgets('выбор из списка подставляет URL', (tester) async {
      await pumpTab(tester);
      expect(find.text(kDiagnosticChecks.first.url), findsOneWidget);
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('diag-endpoint')),
          matching: find.byIcon(Icons.arrow_drop_down)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kDiagnosticChecks[3].title).last);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field()).controller!.text,
          kDiagnosticChecks[3].url);
      await tester.tap(find.byKey(const ValueKey('diag-run')));
      await tester.pumpAndSettle();
      expect(links, [kDiagnosticChecks[3].url]);
    });

    testWidgets('свой URL уходит в прогон', (tester) async {
      await pumpTab(tester);
      await tester.enterText(field(), 'https://example.com/ip');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('diag-run')));
      await tester.pumpAndSettle();
      expect(links, ['https://example.com/ip']);
    });

    testWidgets('невалидный URL блокирует Run', (tester) async {
      await pumpTab(tester);
      await tester.enterText(field(), 'ftp://example.com');
      await tester.pump();
      expect(runButton(tester).onPressed, isNull);
      expect(find.text('Enter an http:// or https:// address'), findsOneWidget);
      await tester.enterText(field(), 'http://example.com');
      await tester.pump();
      expect(runButton(tester).onPressed, isNotNull);
    });
  });

  group('остров только у direct', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('lxbox_725_');
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

    Future<void> openDiagnostics(WidgetTester tester, String tag) async {
      final home = HomeController();
      addTearDown(home.dispose);
      final config = ParsedConfig.parse(jsonEncode({
        'outbounds': [
          {'type': 'direct', 'tag': 'direct-out'},
          {'type': 'vless', 'tag': 'X', 'server': 'x.example',
            'server_port': 443},
        ],
      }));
      await tester.pumpWidget(MaterialApp(
        home: OutboundViewScreen(
          tag: tag,
          kind: 'outbound',
          json: '{}',
          detourCount: 0,
          onCopy: (_) {},
          config: config,
          subController: SubscriptionController(),
          homeController: home,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Diagnostics'));
      await tester.pumpAndSettle();
    }

    testWidgets('direct — остров есть', (tester) async {
      await openDiagnostics(tester, 'direct-out');
      expect(find.byType(PathMtuIsland), findsOneWidget);
    });

    testWidgets('прокси-узел — острова нет', (tester) async {
      await openDiagnostics(tester, 'X');
      expect(find.text('Check'), findsOneWidget);
      expect(find.byType(PathMtuIsland), findsNothing);
    });
  });
}
