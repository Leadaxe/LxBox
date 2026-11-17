import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/config_dirty_check.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/backup.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/lx_backup_import.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/template_loader.dart';
import 'package:lxbox/services/workspaces/workspace_controller.dart';

import '../parser/engine_test_setup.dart';
import '../storage_migration/golden_harness.dart';

/// §748 — импорт бэкапа пишет хранилище мимо контроллеров главного экрана.
///
/// Дефект: `SubscriptionController` держит снимок источников, прочитанный при
/// `init()`, и `_persist()` переписывает весь набор своим составом. Первая
/// мутация после импорта (тумблер у другого сервера) затирала импортированное.
///
/// Решение: после записи импорт зовёт
/// `WorkspaceController.remountAfterExternalWrite()` — прежний контроллер
/// становится `stale` (барьер §515) и не пишет, новый читает свежее
/// хранилище. Без вызова remount тесты ниже падают на «импортированное на
/// месте» (негативный прогон, спека 748 → «Проверка»).
void main() {
  setUpAll(loadEngineSections);
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    LocaleController.I.setting = 'en';
    await TemplateLoader.load();
  });
  tearDownAll(() {
    TemplateLoader.invalidate();
    LocaleController.I.setting = 'system';
  });

  const urlKept = 'http://x/kept';

  SubscriptionServers sub(String url) => SubscriptionServers(
    id: url.split('/').last,
    name: url.split('/').last,
    enabled: true,
    tagPrefix: '',
    detourPolicy: DetourPolicy.defaults,
    url: url,
  );

  /// LX-файл с одним сервером — то, что пользователь импортирует обратно.
  final lxFile = jsonEncode({
    'lx_backup': 2,
    'exported_by': {'app': 'lxbox', 'version': '2.25.22'},
    'exported_at': '2026-11-17T00:00:00Z',
    'sources': [
      {
        'kind': 'server',
        'id': '01SRV748000000000000000000',
        'tag': 'imported-748',
        'enabled': true,
        'body': {
          'type': 'trojan',
          'server': 'example-4.com',
          'server_port': 443,
          'password': 'testpass748',
        },
      },
    ],
  });

  /// Есть ли импортированный сервер на диске (кэш сброшен — читаем файл).
  Future<bool> importedOnDisk() async {
    await SettingsStorage.flushToDisk();
    SettingsStorage.resetCacheForTesting();
    final lists = await SettingsStorage.getServerLists();
    return lists.any((l) => l is! SubscriptionServers);
  }

  Future<SubscriptionController> initialController() async {
    await SettingsStorage.saveServerLists([sub(urlKept)]);
    final c = SubscriptionController();
    await c.init();
    await c.rehydrationDone;
    expect(c.entries, hasLength(1));
    return c;
  }

  late StorageSandbox box;
  setUp(() async {
    box = await StorageSandbox.create();
    ConfigDirtyCheck.resetForTesting();
  });
  tearDown(() => box.dispose());

  test(
    'LX-импорт: тумблер прежнего контроллера не затирает импортированное',
    () async {
      final old = await initialController();

      // Экраны поверх корня закрываются ДО пересоздания (их контроллеры
      // устарели бы, а правки на них молча не писались бы).
      final genAtHook = <int>[];
      WorkspaceController.I.onExternalRemount = () =>
          genAtHook.add(WorkspaceController.I.generation);
      addTearDown(() => WorkspaceController.I.onExternalRemount = null);
      final genBefore = WorkspaceController.I.generation;

      const importer = LxBackupImportService();
      await importer.apply(await importer.prepare(lxFile));
      await WorkspaceController.I.remountAfterExternalWrite();
      expect(genAtHook, [genBefore], reason: 'хук один раз, до generation++');

      // Шаг 3 воспроизведения: мутация в списке Servers до перезапуска.
      await old.toggleAt(0);

      expect(
        await importedOnDisk(),
        isTrue,
        reason: 'импортированный сервер остался в хранилище',
      );
      expect(old.stale, isTrue, reason: 'прежний контроллер больше не владеет');

      // Новый HomeScreen — новый контроллер: импортированное видно сразу.
      final fresh = SubscriptionController();
      await fresh.init();
      await fresh.rehydrationDone;
      expect(fresh.entries.map((e) => e.list.enabled), [
        true,
        true,
      ], reason: 'и свой сервер, и импортированный; тумблер старого не лёг');
      expect(
        SettingsStorage.configDirty,
        isTrue,
        reason: 'новый HomeScreen пересоберёт конфиг',
      );
    },
  );

  test('POST /backup/import: тот же remount, мутация прежнего контроллера '
      'не затирает импортированное', () async {
    // Файл экспорта: свой сервер + пользовательский; затем пользовательский
    // удалён, и контроллер видит только свой.
    await SettingsStorage.saveServerLists([
      sub(urlKept),
      UserServer(
        id: 'srv-748',
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody:
            'vless://11111111-1111-1111-1111-111111111111'
            '@198.51.100.1:443?type=ws&security=tls#Imported',
      ),
    ]);
    await SettingsStorage.flushToDisk();
    final storage =
        jsonDecode(box.settingsFile.readAsStringSync()) as Map<String, dynamic>;
    final old = await initialController();
    DebugRegistry.I.sub = old;
    addTearDown(() => DebugRegistry.I.sub = null);

    final genBefore = WorkspaceController.I.generation;
    final r = await backupHandler(
      DebugRequest.forTest(
        method: 'POST',
        path: '/backup/import',
        body: utf8.encode(jsonEncode({'storage': storage})),
      ),
      DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 11, 17),
      ),
    );
    await old.toggleAt(0);

    expect(
      await importedOnDisk(),
      isTrue,
      reason: 'импортированный сервер остался в хранилище',
    );
    final applied = ((r as JsonResponse).body as Map)['applied'] as Map;
    expect(applied['remounted'], isTrue);
    expect(
      WorkspaceController.I.generation,
      genBefore + 1,
      reason: 'сцена пересоздаётся после записи',
    );
    expect(old.stale, isTrue);
  });
}
