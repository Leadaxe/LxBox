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
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/models/source_entry.dart';
import 'package:lxbox/screens/subscriptions_screen.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/auto_updater.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

// §524 — экран Servers рисует ОДИН список источников: подписки, серверы, папки
// и цепочки в порядке `sources[]`, строками одного рода.
//
// До §524 экран сшивал три источника истины (`entries` контроллера, буфер
// цепочек, `List<String>` ключей) в `_rows()` на каждый кадр, а один drag писал
// на диск ДВАЖДЫ (`reorderSources` + `applyEntryOrder`), каждая запись падала
// независимо. Здесь проверяется, что строк ровно столько, сколько записей, что
// порядок берётся с диска, и что жест даёт ОДНУ запись.
//
// `pumpAndSettle` не используется (§504): таймеры экрана фейковые, кадры
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

/// Контроллер без сборки конфига и без диска.
///
/// `applySourceOrder` перехвачен и НЕ идёт в хранилище: настоящий файловый I/O
/// в fake-async зоне `testWidgets` не завершается никогда (та же грабля, что в
/// `subscriptions_new_entry_highlight_test.dart`). Тест смотрит на ЧИСЛО
/// вызовов и на переданные ключи — ровно то, что §524 менял: одна запись на
/// жест вместо двух.
class _CountingSubController extends SubscriptionController {
  final orderCalls = <List<String>>[];

  /// Список, который отдаётся экрану вместо чтения с диска.
  List<SourceEntry> scene = const [];

  @override
  Future<String?> generateConfig() async => '{"outbounds":[]}';

  @override
  Future<List<SourceEntry>> sourceEntries() async => scene;

  @override
  Future<bool> applySourceOrder(List<String> keys) async {
    orderCalls.add(keys);
    // Применяем в памяти, как это сделала бы запись на диск.
    final rank = {for (var i = 0; i < keys.length; i++) keys[i]: i};
    scene = [...scene]
      ..sort((a, b) => (rank[a.sourceKey] ?? rank.length)
          .compareTo(rank[b.sourceKey] ?? rank.length));
    notifyListeners();
    return true;
  }
}

SubscriptionEntry _entry(String id, String uri, String name) =>
    SubscriptionEntry(
      list: UserServer(
        id: id,
        name: name,
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: uri,
        nodes: [parseUri(uri)!],
      ),
      nodeCount: 1,
    );

String _uri(int i, String tag) =>
    'vless://u$i@h$i.example:443?type=ws&security=tls#$tag';

const _hops = [NodeLink(tag: 'a'), NodeLink(tag: 'b')];

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
  late _CountingSubController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('unified_list_');
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
    controller = _CountingSubController();
    // Настоящая зона: прогрев хранилища и состав записей в памяти. Смешанный
    // список — сервер, ЦЕПОЧКА, сервер: цепочка стоит МЕЖДУ контейнерами,
    // а не хвостом (§509).
    await controller.init();
    await SettingsStorage.getAutoUpdateSubs();
    final first = _entry('u1', _uri(1, 'First'), 'First');
    final second = _entry('u2', _uri(2, 'Second'), 'Second');
    controller.debugSetEntries([first, second]);
    controller.scene = [
      ContainerEntry(first.list),
      ChainEntry(const SourceChain(tag: 'c1', label: 'Via', hops: _hops)),
      ContainerEntry(second.list),
    ];
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

  testWidgets('строки одного списка: цепочка между серверами, в порядке диска',
      (tester) async {
    final home = HomeController();
    addTearDown(home.dispose);
    await _pumpServersScreen(tester, controller: controller, home: home);

    // Контроллер держит только контейнеры; экран рисует ВСЕ записи.
    expect(controller.entries.map((e) => e.id), ['u1', 'u2']);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Via'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);

    // Порядок на экране — порядок `sources[]`, а не «сначала контейнеры».
    final yFirst = tester.getCenter(find.text('First')).dy;
    final yVia = tester.getCenter(find.text('Via')).dy;
    final ySecond = tester.getCenter(find.text('Second')).dy;
    expect(yFirst, lessThan(yVia));
    expect(yVia, lessThan(ySecond));
  });

  testWidgets('перестановка — ОДНА запись на жест', (tester) async {
    final home = HomeController();
    addTearDown(home.dispose);
    await _pumpServersScreen(tester, controller: controller, home: home);

    expect(controller.orderCalls, isEmpty);
    final state = tester.state<State<SubscriptionsScreen>>(
        find.byType(SubscriptionsScreen));
    // Жест: первая строка (сервер u1) уезжает в конец списка.
    await (state as dynamic).debugReorderRows(0, 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(controller.orderCalls, hasLength(1),
        reason: 'до §524 жест писал дважды, каждая запись падала независимо');
    // Ключи ОБОИХ родов в одном списке — цепочка адресуется наравне.
    expect(controller.orderCalls.single, ['chain:c1', 'id:u2', 'id:u1']);
    expect(controller.scene.map((e) => e.sourceKey),
        ['chain:c1', 'id:u2', 'id:u1']);
  });

  testWidgets('удаление записи из середины соседей не двигает', (tester) async {
    final home = HomeController();
    addTearDown(home.dispose);
    await _pumpServersScreen(tester, controller: controller, home: home);

    // §511 M1 — цепочка ушла из СЕРЕДИНЫ списка: серверы остаются на местах,
    // в освободившееся место никто не съезжает.
    controller.scene = [
      for (final e in controller.scene)
        if (e.sourceKey != 'chain:c1') e,
    ];
    final state = tester.state<State<SubscriptionsScreen>>(
        find.byType(SubscriptionsScreen));
    await (state as dynamic).debugReloadSources();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Via'), findsNothing);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(tester.getCenter(find.text('First')).dy,
        lessThan(tester.getCenter(find.text('Second')).dy));
  });
}
