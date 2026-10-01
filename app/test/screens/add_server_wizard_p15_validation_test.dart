// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/screens/add_server_wizard_screen.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

class _Launcher extends StatelessWidget {
  const _Launcher(this.controller);
  final SubscriptionController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AddServerWizardScreen(
                subController: controller,
                onAdded: () async {},
              ),
            ),
          ),
          child: const Text('open wizard'),
        ),
      ),
    );
  }
}

/// 008-NODE_EDITOR P15 — «Proxy forms do not accept an invalid address»:
/// Host non-empty, Port 1..65535, иначе Add не срабатывает. `no witness`
/// в FEATURE.md на момент написания — первый тест валидатора SOCKS5/HTTP.
void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('wizard_p15_');
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

  Future<SubscriptionController> openWizard(WidgetTester tester) async {
    final c = SubscriptionController();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: LocaleController.supportedLocales,
      home: _Launcher(c),
    ));
    await tester.tap(find.text('open wizard'));
    await tester.pumpAndSettle();
    return c;
  }

  /// Поля формы по порядку: Tag(0), Host(1), Port(2), Username(3), Password(4).
  Finder field(int i) => find.byType(TextFormField).at(i);

  group('P15 SOCKS5 form validation', () {
    testWidgets('пустой Host → валидатор не пускает, ничего не добавлено',
        (tester) async {
      final c = await openWizard(tester);
      await tester.enterText(field(1), '');
      await tester.enterText(field(2), '1080');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text('Host required'), findsOneWidget);
      expect(c.entries, isEmpty);
    });

    testWidgets('Port 0 → валидатор не пускает, ничего не добавлено',
        (tester) async {
      final c = await openWizard(tester);
      await tester.enterText(field(2), '0');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text('Port 1..65535'), findsOneWidget);
      expect(c.entries, isEmpty);
    });

    testWidgets('Port 65536 (за пределами) → валидатор не пускает',
        (tester) async {
      final c = await openWizard(tester);
      await tester.enterText(field(2), '65536');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text('Port 1..65535'), findsOneWidget);
      expect(c.entries, isEmpty);
    });
  });

  group('P15 HTTP form validation', () {
    testWidgets('пустой Host → валидатор не пускает, ничего не добавлено',
        (tester) async {
      final c = await openWizard(tester);
      await tester.tap(find.text('HTTP'));
      await tester.pumpAndSettle();
      await tester.enterText(field(1), '');
      await tester.enterText(field(2), '8080');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text('Host required'), findsOneWidget);
      expect(c.entries, isEmpty);
    });

    testWidgets('Port 0 → валидатор не пускает, ничего не добавлено',
        (tester) async {
      final c = await openWizard(tester);
      await tester.tap(find.text('HTTP'));
      await tester.pumpAndSettle();
      await tester.enterText(field(2), '0');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text('Port 1..65535'), findsOneWidget);
      expect(c.entries, isEmpty);
    });
  });
}
