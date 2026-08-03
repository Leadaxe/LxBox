// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
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

/// §360 — гонка toggle ↔ пересборка: мутация, попавшая в окно `_busy`, не
/// должна терять `configDirty`.
void main() {
  late Directory tempDir;

  const uriA = 'vless://u1@h1.example:443?type=ws&security=tls#Alpha';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('toggle_race_');
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

  test('toggleAt во время generateConfig не теряет configDirty', () async {
    final c = SubscriptionController();
    await c.init();
    await c.addFolder('F');
    await c.addMembersToFolder(0, uriA);

    // Пересборка в полёте: не ждём её, а переключаем подписку внутри окна
    // `_busy` — ровно то, что делает юзер, тапнув галку сразу после возврата.
    final gen = c.generateConfig();
    // `generateConfig` открывается с await на storage-lock, поэтому `_busy`
    // взводится не синхронно — дожидаемся реального окна.
    while (!c.busy) {
      await Future<void>.delayed(Duration.zero);
    }
    await c.toggleAt(0);
    await gen;

    expect(c.entries.single.enabled, isFalse, reason: 'toggle применился');
    expect(c.configDirty, isTrue,
        reason: 'мутация в окне _busy обязана оставить pending changes');
  });

  test('пересборка без параллельных мутаций гасит configDirty', () async {
    final c = SubscriptionController();
    await c.init();
    await c.addFolder('F');
    await c.addMembersToFolder(0, uriA);
    expect(c.configDirty, isTrue);

    await c.generateConfig();

    expect(c.configDirty, isFalse,
        reason: 'состав не менялся под пересборкой — флаг обязан сняться');
  });

  test('addUserServer поднимает configDirty (свой _busy не глушит)', () async {
    final c = SubscriptionController();
    await c.init();
    await c.addFolder('F');
    await c.addMembersToFolder(0, uriA);
    await c.generateConfig();
    expect(c.configDirty, isFalse);

    await c.addUserServer(UserServer(
      id: 'u-1',
      name: 'Manual',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.manual,
      createdAt: DateTime.now(),
      rawBody: uriA,
      nodes: [parseUri(uriA)!],
    ));

    expect(c.entries, hasLength(2));
    expect(c.configDirty, isTrue,
        reason: 'добавленный сервер обязан попасть в конфиг');
  });
}
