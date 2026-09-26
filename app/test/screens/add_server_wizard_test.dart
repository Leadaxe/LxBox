// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/node_spec.dart';
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
/// Путь рестарта: сервер через запись `sources[]` и обратно (§439).
UserServer _storageRoundTrip(UserServer us) =>
    sourceFromRecord(sourceToRecord(us)).value! as UserServer;

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
      final reloaded = _storageRoundTrip(us);
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

      final reloaded = _storageRoundTrip(us);
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

  group('§435 Tailscale form', () {
    /// Открыть вкладку Tailscale (последняя — индексы прежних не поехали).
    Future<SubscriptionController> openTailscale(WidgetTester tester) async {
      final c = await openWizard(tester);
      await tester.tap(find.text('Tailscale'));
      await tester.pumpAndSettle();
      return c;
    }

    /// Поля формы по порядку: Tag, Auth key, Control URL, Hostname, Exit node.
    Finder field(int i) => find.byType(TextFormField).at(i);

    testWidgets('Tag + Auth key → TailscaleSpec, JSON-rawBody, три записи секций',
        (tester) async {
      final c = await openTailscale(tester);
      await tester.enterText(field(0), '🪢 My tailnet');
      await tester.enterText(field(1), 'tskey-auth-secret');
      await submit(tester, c);

      expect(c.lastError, isNull);
      final entry = c.entries.single;
      final us = entry.list as UserServer;
      expect(us.name, '');
      expect(us.origin, UserSource.manual);
      final node = us.nodes.single;
      expect(node, isA<TailscaleSpec>());
      expect(node.tag, '🪢 My tailnet');
      expect(entry.displayName, '🪢 My tailnet');
      expect(node.isAddressless, isTrue);
      expect((node as TailscaleSpec).body.containsKey('exit_node'), isFalse);
      expect(node.body['auth_key'], 'tskey-auth-secret');
      // §449 — Hostname приходит с дефолтом; в тестах модель устройства пуста
      // (`SubscriptionIdentity.init` не звался), отсюда голый префикс.
      expect(node.body['hostname'], 'LxBox');
      // Пустые поля и выключенные тумблеры в тело не пишутся.
      expect(node.body.containsKey('control_url'), isFalse);
      expect(node.body.containsKey('ephemeral'), isFalse);
      expect(node.body.containsKey('accept_routes'), isFalse);
      expect(node.body.containsKey('exit_node'), isFalse);

      expect(us.rawBody, contains('"type":"tailscale"'));
      expect(us.rawBody, contains('"auth_key":"tskey-auth-secret"'));

      final s = us.sections;
      expect(s, isNotNull);
      expect(s!.recordCount, 3);
      expect(s.rules.single.name, '@{self} network');
      expect(s.rules.single.orderNum, 945);
      expect(s.dnsServers.single.tag, '@{self}-dns');
      expect(s.dnsRules.single.rule['server'], '@{self}-dns');
    });

    testWidgets('§449 Hostname с дефолтом LxBox, стирание возвращает пустое тело',
        (tester) async {
      final c = await openTailscale(tester);
      // Поле открывается заполненным — юзер видит имя до создания узла.
      expect(find.text('LxBox'), findsOneWidget);

      await tester.enterText(field(0), '🪢 Wiped');
      await tester.enterText(field(1), 'tskey-auth-w');
      await tester.enterText(field(3), '');
      await submit(tester, c);

      final node = (c.entries.single.list as UserServer).nodes.single;
      // Пусто = имя выбирает tsnet, как было до §449.
      expect((node as TailscaleSpec).body.containsKey('hostname'), isFalse);
    });

    testWidgets('round-trip записи sources[]: узел и секции целы',
        (tester) async {
      final c = await openTailscale(tester);
      await tester.enterText(field(0), '🪢 Keep');
      await tester.enterText(field(1), 'tskey-auth-x');
      await submit(tester, c);

      final us = c.entries.single.list as UserServer;
      final reloaded = _storageRoundTrip(us);
      expect(reloaded.name, '');
      final node = reloaded.nodes.single;
      expect(node, isA<TailscaleSpec>());
      expect(node.tag, '🪢 Keep');
      expect((node as TailscaleSpec).body['auth_key'], 'tskey-auth-x');
      expect(reloaded.sections?.recordCount, 3);
      expect(reloaded.sections!.toJson(), us.sections!.toJson());
    });

    testWidgets('пустой Tag → «tailscale» с эмодзи по умолчанию 🪢',
        (tester) async {
      final c = await openTailscale(tester);
      await tester.enterText(field(1), 'tskey-auth-x');
      await submit(tester, c);

      expect(c.lastError, isNull);
      final us = c.entries.single.list as UserServer;
      expect(us.nodes.single.tag, '🪢 tailscale');
      expect(us.sections?.recordCount, 3);
    });

    testWidgets('необязательные поля и тумблеры попадают в тело как есть',
        (tester) async {
      final c = await openTailscale(tester);
      await tester.enterText(field(1), 'tskey-auth-x');
      await tester.enterText(field(2), 'https://hs.example.com');
      await tester.enterText(field(3), 'phone');
      await tester.enterText(field(4), 'exit-1');
      // Тумблеры ниже тестового вьюпорта 800×600 — доскроллить перед тапом.
      for (final title in ['Ephemeral', 'Accept routes']) {
        final tile = find.widgetWithText(SwitchListTile, title);
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        await tester.tap(tile);
      }
      await tester.pumpAndSettle();
      await submit(tester, c);

      final node = (c.entries.single.list as UserServer).nodes.single
          as TailscaleSpec;
      expect(node.body['control_url'], 'https://hs.example.com');
      expect(node.body['hostname'], 'phone');
      expect(node.body['exit_node'], 'exit-1');
      expect(node.body['ephemeral'], isTrue);
      expect(node.body['accept_routes'], isTrue);
    });

    testWidgets('пустой Auth key → валидатор не пускает, ничего не добавлено',
        (tester) async {
      final c = await openTailscale(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text('Auth key required'), findsOneWidget);
      expect(c.entries, isEmpty);
      // Мастер остался открыт.
      expect(find.text('Tailscale'), findsOneWidget);
    });

    testWidgets('подсказка про одноразовый ключ и Exit node на месте',
        (tester) async {
      await openTailscale(tester);
      expect(find.textContaining('A one-time key is consumed'), findsOneWidget);
      expect(find.textContaining('will not appear in Directions'),
          findsOneWidget);
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
