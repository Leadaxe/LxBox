// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/l10n/l10n.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
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

/// Launcher-обёртка: wizard пушится отдельным route'ом, чтобы его
/// `Navigator.pop()` после успешного Add было куда возвращаться.
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

/// §243 — визард (§074 SOCKS5 / §222 HTTP): поле «Display name» удалено,
/// заголовок записи = tag узла. Поле Tag опционально: введённое значение →
/// tag (живёт в rawBody-JSON, переживает рестарт), пусто → дефолтный tag.
/// `UserServer.name` визард всегда пишет пустым.
void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('wizard_tag_');
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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: _Launcher(c),
    ));
    await tester.tap(find.text('open wizard'));
    await tester.pumpAndSettle();
    return c;
  }

  /// Тап по Add + дожидание file-IO persist'а (`runAsync` — реальный event
  /// loop, иначе fake-async зона testWidgets не даст dart:io завершиться),
  /// затем пятисекундный pump — гасит snackbar-таймер («Timer still pending»).
  Future<void> submit(WidgetTester tester, SubscriptionController c) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.runAsync(() async {
      for (var i = 0; i < 400 && c.entries.isEmpty && c.lastError == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  group('§243 SOCKS5 form', () {
    testWidgets('заполненный Tag → tag узла = введённое, name пуст',
        (tester) async {
      final c = await openWizard(tester);
      // Первое поле SOCKS-формы — Tag. Эмодзи в теге → авто-эмодзи (§090
      // G2b) не префиксует, tag сохраняется дословно.
      await tester.enterText(find.byType(TextFormField).first, '🚀 My proxy');
      await submit(tester, c);

      expect(c.lastError, isNull);
      final entry = c.entries.single;
      final us = entry.list as UserServer;
      expect(us.name, ''); // §243 — визард name больше не пишет
      expect(us.nodes.single.tag, '🚀 My proxy');
      expect(entry.displayName, '🚀 My proxy');
    });

    testWidgets('пустое поле Tag → дефолтный tag (как раньше)',
        (tester) async {
      final c = await openWizard(tester);
      await submit(tester, c);

      expect(c.lastError, isNull);
      final us = c.entries.single.list as UserServer;
      expect(us.name, '');
      // Дефолтный host = 127.0.0.1 → авто-эмодзи 🔁 (localhost).
      expect(us.nodes.single.tag, '🔁 local-socks5-out');
    });

    testWidgets('tag без эмодзи получает дефолтный префикс, текст цел',
        (tester) async {
      final c = await openWizard(tester);
      await tester.enterText(find.byType(TextFormField).first, 'team proxy');
      await submit(tester, c);

      final us = c.entries.single.list as UserServer;
      expect(us.nodes.single.tag, '🔁 team proxy');
    });

    testWidgets('введённый tag переживает persist round-trip (rawBody)',
        (tester) async {
      final c = await openWizard(tester);
      await tester.enterText(find.byType(TextFormField).first, '🚀 Keep me');
      await submit(tester, c);

      final us = c.entries.single.list as UserServer;
      // Путь рестарта: UserServer персистит только rawBody (JSON outbound),
      // ноды ре-деривятся parseSingboxEntry'ом — tag обязан выжить.
      final reloaded = UserServer.fromJson(us.toJson());
      expect(reloaded.name, '');
      expect(reloaded.nodes.single.tag, '🚀 Keep me');
    });
  });

  group('§243 HTTP form (§222)', () {
    testWidgets('заполненный Tag → tag узла = введённое, name пуст',
        (tester) async {
      final c = await openWizard(tester);
      await tester.tap(find.text('HTTP'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, '🌍 Corp http');
      await submit(tester, c);

      expect(c.lastError, isNull);
      final us = c.entries.single.list as UserServer;
      expect(us.name, '');
      expect(us.nodes.single.tag, '🌍 Corp http');

      final reloaded = UserServer.fromJson(us.toJson());
      expect(reloaded.nodes.single.tag, '🌍 Corp http');
    });

    testWidgets('пустое поле Tag → дефолтный tag', (tester) async {
      final c = await openWizard(tester);
      await tester.tap(find.text('HTTP'));
      await tester.pumpAndSettle();
      await submit(tester, c);

      final us = c.entries.single.list as UserServer;
      expect(us.name, '');
      expect(us.nodes.single.tag, '🔁 local-http-out');
    });
  });

  group('§243 UI-строки', () {
    testWidgets('поля «Display name» больше нет, Tag optional с helper',
        (tester) async {
      await openWizard(tester);
      // SOCKS tab (default).
      expect(find.text('Display name (optional)'), findsNothing);
      expect(find.text('Tag (optional)'), findsOneWidget);
      expect(
        find.textContaining('Shown as the server title'),
        findsOneWidget,
      );

      await tester.tap(find.text('HTTP'));
      await tester.pumpAndSettle();
      expect(find.text('Display name (optional)'), findsNothing);
      expect(find.text('Tag (optional)'), findsOneWidget);
      expect(
        find.textContaining('Shown as the server title'),
        findsOneWidget,
      );
    });
  });
}
