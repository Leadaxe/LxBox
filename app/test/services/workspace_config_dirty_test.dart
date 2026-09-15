import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/services/config_dirty_check.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/workspaces/workspace_controller.dart';

/// §447 — загрузка слота Workspaces помечает конфиг грязным явно. Раньше
/// признаком был только mtime настроек (§417 §2.3 шаг 8), а его гасили flush
/// перед загрузкой (touch конфига в ту же секунду) и любой `_save()` при
/// снятом флаге: новый HomeScreen видел `dirty=false`, VPN шёл с конфигом
/// прежнего слота.
void main() {
  late Directory docs;
  late Directory support;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final ws = WorkspaceController.I;

  const uriAlpha = 'vless://u1@h1.example:443?type=ws&security=tls#Alpha';
  const uriBeta = 'vless://u2@h2.example:443?type=ws&security=tls#Beta';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    docs = await Directory.systemTemp.createTemp('lxbox_ws_dirty_docs_');
    support = await Directory.systemTemp.createTemp('lxbox_ws_dirty_support_');
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
    ConfigDirtyCheck.resetForTesting();
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

  /// Запись собранного конфига, как её делает `saveParsedConfig`: файл
  /// конфига (в тестах канала нет — рядом с настройками) + снятый флаг и
  /// выровненный mtime.
  Future<void> applyConfig(String config) async {
    await File('${docs.path}/singbox_config.json').writeAsString(config);
    SettingsStorage.configDirty = false;
    await SettingsStorage.flushToDisk();
  }

  /// Bootstrap нового HomeScreen: `init` → при `configDirty` пересборка.
  Future<SubscriptionController> bootstrap() async {
    final c = SubscriptionController();
    await c.init();
    return c;
  }

  test('загрузка слота → configDirty → сборка из настроек нового слота',
      () async {
    final c = await bootstrap();
    await c.addFolder('F');
    await c.addMembersToFolder(0, uriAlpha);
    await applyConfig((await c.generateConfig())!);
    await ws.saveAs('Home');

    await c.addMembersToFolder(0, uriBeta);
    await applyConfig((await c.generateConfig())!);
    await ws.saveAs('Work');

    // Home на сцене, конфиг пересобран и чист.
    await ws.load('Home', stopVpn: () async => false);
    final home = await bootstrap();
    expect(home.configDirty, isTrue);
    final homeConfig = (await home.generateConfig())!;
    expect(homeConfig, contains('Alpha'));
    expect(homeConfig, isNot(contains('Beta')));
    await applyConfig(homeConfig);
    expect(SettingsStorage.configDirty, isFalse);

    // Сценарий бага: Home → Work сразу после чистой записи.
    await ws.load('Work', stopVpn: () async => false);
    expect(SettingsStorage.configDirty, isTrue,
        reason: 'загрузка слота помечает конфиг грязным явно');

    // Запись настроек между загрузкой и bootstrap'ом (шаги перечитывания,
    // фоновые писатели) при поднятом флаге mtime конфига не выравнивает.
    await SettingsStorage.setVar('workspace_dirty_probe', '1');

    final work = await bootstrap();
    expect(work.configDirty, isTrue,
        reason: 'bootstrap обязан пересобрать конфиг слота');
    final workConfig = (await work.generateConfig())!;
    expect(workConfig, contains('Beta'),
        reason: 'конфиг собран из настроек загруженного слота');
    expect(work.configDirty, isFalse);
  });

  test('init не опускает флаг процесса при выровненном mtime', () async {
    await SettingsStorage.setVar('scene', 'a');
    await File('${docs.path}/singbox_config.json').writeAsString('{}');
    await ConfigDirtyCheck.touchConfig();
    expect(await ConfigDirtyCheck.isDirty(), isFalse);

    SettingsStorage.markConfigDirty();
    final c = await bootstrap();
    expect(c.configDirty, isTrue);
  });

  test('без флага процесса init берёт признак из mtime', () async {
    await SettingsStorage.setVar('scene', 'a');
    await File('${docs.path}/singbox_config.json').writeAsString('{}');
    await ConfigDirtyCheck.touchConfig();
    SettingsStorage.configDirty = false;

    final c = await bootstrap();
    expect(c.configDirty, isFalse);
  });
}
