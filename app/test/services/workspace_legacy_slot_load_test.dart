import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/workspaces/workspace_controller.dart';
import 'package:lxbox/services/workspaces/workspace_store.dart';

/// §439 §3.3 — слот Workspaces с файлом настроек формы 2.23.2 (слоты спят и
/// не мигрируют до загрузки): загрузка мигрирует рабочую копию штатным
/// `_load()`, а исходник слота остаётся в `workspaces/<имя>/` копией
/// `lxbox_settings.json.v0.bak` — копия рядом с рабочим файлом уже держит
/// исходник первой миграции и слот не запишет.
void main() {
  late Directory docs;
  late Directory support;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final ws = WorkspaceController.I;

  File scene() => File('${docs.path}/lxbox_settings.json');
  File sceneV0() => File('${docs.path}/lxbox_settings.json.v0.bak');
  File slotFile(String name) =>
      File('${docs.path}/workspaces/$name/lxbox_settings.json');
  File slotV0(String name) =>
      File('${docs.path}/workspaces/$name/lxbox_settings.json.v0.bak');
  Map<String, dynamic> read(File f) =>
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;

  /// Файл слота, каким его сохранила 2.23.2.
  String legacySlot(String sourceId) => const JsonEncoder.withIndent('  ')
      .convert({
        'vars': {'scene': 'old'},
        'server_lists': [
          {
            'type': 'user',
            'id': sourceId,
            'name': '',
            'enabled': true,
            'raw_body': 'vless://11111111-1111-1111-1111-111111111111'
                '@198.51.100.1:443?type=ws&security=tls#Tokyo',
          },
        ],
        'chains': [
          {'tag': 'c1', 'hops': ['Tokyo', 'vpn-1'], 'order': 4},
        ],
        'custom_rules': [
          {
            'id': 'r1',
            'name': 'Ads',
            'kind': 'inline',
            'domainSuffixes': ['.ads.example'],
            'outbound': 'reject',
          },
        ],
        'directions': [
          {'tag': 'vpn-1', 'label': 'Main', 'enabled': true},
        ],
        'directions_migrated': true,
      });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    docs = await Directory.systemTemp.createTemp('lxbox_ws_legacy_docs_');
    support = await Directory.systemTemp.createTemp('lxbox_ws_legacy_support_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
        case 'getApplicationDocumentsPath':
          return docs.path;
        case 'getApplicationSupportDirectory':
        case 'getApplicationSupportPath':
          return support.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
    // Сцена текущей формы; исходник первой миграции уже лежит рядом.
    await scene().writeAsString(jsonEncode({
      'storage_version': 1,
      'vars': {'scene': 'home'},
      'directions': [
        {'tag': 'vpn-1', 'label': 'Main', 'enabled': true},
      ],
      'directions_migrated': true,
    }));
    await sceneV0().writeAsString('{"first":"migration"}');
    await ws.refresh();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SettingsStorage.resetCacheForTesting();
    for (final d in [docs, support]) {
      try {
        if (d.existsSync()) await d.delete(recursive: true);
      } on FileSystemException {
        // AppLog пишет persistent-лог в docs async — race с delete.
      }
    }
  });

  /// Слоты «Old» и «Home», на сцене — «Home»; файл слота «Old» — форма 2.23.2.
  Future<String> prepareLegacySlot() async {
    await ws.saveAs('Old');
    await ws.saveAs('Home');
    final legacy = legacySlot('srv-old');
    await slotFile('Old').writeAsString(legacy);
    return legacy;
  }

  test('загрузка слота 2.23.2: сцена мигрирует, исходник слота — копией в '
      'папке слота, копия сцены не тронута', () async {
    final legacy = await prepareLegacySlot();

    final outcome = await ws.load('Old', stopVpn: () async => false);
    expect(outcome, WorkspaceLoadOutcome.loaded);

    expect(slotV0('Old').readAsStringSync(), legacy,
        reason: 'исходные байты слота');
    expect(sceneV0().readAsStringSync(), '{"first":"migration"}',
        reason: 'копия первой миграции не перетирается');

    // Состояние перечитано моделями из мигрированной сцены.
    expect((await SettingsStorage.getServerLists()).single.id, 'srv-old');
    expect((await SettingsStorage.getChains()).single.hops, ['Tokyo', 'vpn-1']);
    expect((await SettingsStorage.getCustomRules()).single.name, 'Ads');
    final onScene = read(scene());
    expect(onScene['storage_version'], 1);
    expect(onScene.containsKey('server_lists'), isFalse);
    expect((onScene['vars'] as Map)['scene'], 'old');

    // Копия слота на сцену не едет.
    expect(WorkspaceStore.kSlotEntries.map((e) => e.name),
        isNot(contains('lxbox_settings.json.v0.bak')));
  });

  test('слот сохраняется обратно уже в форме 1.0, копия остаётся первой',
      () async {
    final legacy = await prepareLegacySlot();
    await ws.load('Old', stopVpn: () async => false);
    await ws.load('Home', stopVpn: () async => false);

    final savedOld = read(slotFile('Old'));
    expect(savedOld['storage_version'], 1);
    expect(savedOld.containsKey('server_lists'), isFalse);
    expect(slotV0('Old').readAsStringSync(), legacy);

    // Повторная загрузка уже мигрированного слота копию не трогает.
    await slotV0('Old').writeAsString('{"kept":true}');
    await ws.load('Old', stopVpn: () async => false);
    expect(slotV0('Old').readAsStringSync(), '{"kept":true}');
    expect((await SettingsStorage.getServerLists()).single.id, 'srv-old');
  });

  test('слот текущей формы копии не получает', () async {
    await ws.saveAs('Old');
    await ws.saveAs('Home');
    await ws.load('Old', stopVpn: () async => false);
    expect(slotV0('Old').existsSync(), isFalse);
    expect(slotV0('Home').existsSync(), isFalse);
  });
}
