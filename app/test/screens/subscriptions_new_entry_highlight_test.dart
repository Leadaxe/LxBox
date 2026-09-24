// ignore_for_file: depend_on_referenced_packages
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/subscriptions_screen.dart';
import 'package:lxbox/screens/subscriptions_screen/widgets/add_icon_button.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/auto_updater.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

// §504 — подсветка и прокрутка к новой записи на экране Servers.
//
// Весь путь тапа по «+» идёт на фейковых часах `testWidgets`: настоящий
// файловый I/O в fake-async зоне не завершается никогда, поэтому состав
// записей подменяется в памяти, а `generateConfig` отдаёт готовый JSON.
// Хранилище прогревается в `setUp` (зона там настоящая), `saveConfig`
// закрыт моком канала. `pumpAndSettle` не нужен: таймеры 7 с и 400 мс
// прокручиваются `pump(Duration)`.

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

/// Контроллер без хранения и сборки: добавление — запись в памяти.
class _FakeSubController extends SubscriptionController {
  var _seq = 0;

  @override
  Future<String?> generateConfig() async => '{"outbounds":[]}';

  @override
  Future<void> addFromInput(String input,
      {String? nameHint, UserSource origin = UserSource.paste}) async {
    debugSetEntries([...entries, _entry('added-${_seq++}', input.trim())]);
    notifyListeners();
  }

  /// Удаление записи в памяти — как `removeAt`, без `_persist`.
  void dropEntry(String id) {
    debugSetEntries([
      for (final e in entries)
        if (e.id != id) e,
    ]);
    notifyListeners();
  }
}

SubscriptionEntry _entry(String id, String uri) => SubscriptionEntry(
      list: UserServer(
        id: id,
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: uri,
        nodes: [parseUri(uri)!],
      ),
      nodeCount: 1,
    );

const _seedUri = 'vless://u@h.example:443?type=ws&security=tls#SeedEntry';
const _newUri =
    'vless://u-new@h-new.example:443?type=ws&security=tls#BrandNew';

String _seedEntryUri(int i) =>
    'vless://u$i@h$i.example:443?type=ws&security=tls#Seed$i';

Future<void> _pumpServersScreen(
  WidgetTester tester, {
  required SubscriptionController controller,
  required HomeController home,
}) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: LocaleController.supportedLocales,
    home: SubscriptionsScreen(
      subController: controller,
      homeController: home,
      autoUpdater: AutoUpdater(controller),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// Ввод + «+»: add → пересборка → прокрутка (~320 мс) → SnackBar.
Future<void> _submitNewEntry(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), _newUri);
  await tester.tap(find.byType(AddIconButton));
  // Кадры для jumpTo/endOfFrame и ensureVisible; SnackBar выходит после
  // прокрутки. Шаги фиксированные — таймеры фейковые.
  for (var i = 0; i < 20 && find.byType(SnackBar).evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Rect _entryTileRect(WidgetTester tester, String title) {
  final titleFinder = find.text(title);
  expect(titleFinder, findsOneWidget);
  return tester.getRect(
    find.ancestor(of: titleFinder, matching: find.byType(ListTile)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  late Directory tempDir;
  late _FakeSubController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('new_entry_highlight_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async {
        if (call.method == 'saveConfig') return true;
        if (call.method == 'hasCamera') return false;
        return null;
      });
    }
    controller = _FakeSubController();
    // Настоящая зона: хранилище загружается в кэш, дальше экран читает его
    // без диска.
    await controller.init();
    await SettingsStorage.getSourceKeys();
    await SettingsStorage.getChains();
    await SettingsStorage.getAutoUpdateSubs();
  });

  tearDown(() async {
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    SettingsStorage.resetCacheForTesting();
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  group('SubscriptionsScreen — §504 new entry highlight', () {
    late HomeController home;

    Future<void> openScreen(WidgetTester tester, List<SubscriptionEntry> seed,
        {Size size = const Size(400, 520)}) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      controller.debugSetEntries(seed);
      home = HomeController();
      addTearDown(home.dispose);
      // Экран закрывается до конца теста: dispose снимает таймеры 7 с и
      // 400 мс, иначе «A Timer is still pending».
      addTearDown(() async {
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpWidget(const SizedBox());
      });
      await _pumpServersScreen(tester, controller: controller, home: home);
    }

    testWidgets('длинный список: add → строка видима, New, выше SnackBar',
        (tester) async {
      await openScreen(tester, [
        for (var i = 0; i < 12; i++) _entry('seed-$i', _seedEntryUri(i)),
      ]);
      expect(find.text('BrandNew'), findsNothing,
          reason: 'новой записи ещё нет');

      await _submitNewEntry(tester);

      expect(controller.entries.length, 13);
      expect(find.text('BrandNew'), findsOneWidget);
      expect(find.text('New'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);

      final entryRect = _entryTileRect(tester, 'BrandNew');
      final snackRect = tester.getRect(find.byType(SnackBar));
      final scrollable = tester.getRect(find
          .descendant(
            of: find.byType(RefreshIndicator),
            matching: find.byType(Scrollable),
          )
          .first);
      expect(entryRect.top, greaterThanOrEqualTo(scrollable.top));
      expect(entryRect.bottom, lessThanOrEqualTo(scrollable.bottom));
      expect(entryRect.bottom, lessThan(snackRect.top),
          reason: 'новая строка не под SnackBar');
    });

    testWidgets('через 8 с подсветки нет', (tester) async {
      await openScreen(tester, [_entry('seed', _seedUri)]);
      await _submitNewEntry(tester);
      expect(find.text('New'), findsOneWidget);

      await tester.pump(const Duration(seconds: 8));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('New'), findsNothing);
    });

    testWidgets('тап по другой строке снимает подсветку сразу',
        (tester) async {
      await openScreen(tester, [_entry('seed', _seedUri)]);
      await _submitNewEntry(tester);
      expect(find.text('New'), findsOneWidget);

      await tester.tap(find.text('SeedEntry'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.text('New', skipOffstage: false), findsNothing);
    });

    // §511 m1 — подсвеченная запись ушла: подсветка снимается сразу, ключ
    // строки не копится до закрытия экрана.
    testWidgets('удаление подсвеченной записи снимает подсветку и её ключ',
        (tester) async {
      await openScreen(tester, [_entry('seed', _seedUri)]);
      await _submitNewEntry(tester);
      final screen =
          tester.state(find.byType(SubscriptionsScreen)) as dynamic;
      expect(screen.debugHighlightedEntryId, 'added-0');
      expect(screen.debugTileKeyIds, contains('added-0'));

      controller.dropEntry('added-0');
      await tester.pump();
      expect(screen.debugHighlightedEntryId, isNull);
      expect(screen.debugTileKeyIds, isNot(contains('added-0')));
      expect(screen.debugTileKeyIds, contains('seed'));
    });
  });
}
