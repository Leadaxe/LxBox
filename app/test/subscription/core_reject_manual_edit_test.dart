// ignore_for_file: depend_on_referenced_packages

// Фича 478 / PARSING_PRINCIPLES §9.4 п. 1 — ручная правка ТЕЛА узла снимает вердикт ядра
// и включает узел обратно. Здесь проверяются фактические точки сохранения
// редактора: `updateMemberAt` (член папки) и `updateConnectionAt` (ручной
// сервер). Смену тела на refetch подписки закрывает
// `core_reject_storage_test.dart`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tempRoot);
  final String tempRoot;
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

  late Directory tempDir;

  // Тело меняется только полем sni: имя и адрес те же, чтобы правка была
  // именно правкой ТЕЛА, а не заменой узла.
  const uriA = 'vless://u@h.example:443?type=ws&security=tls&sni=x#Alpha';
  const uriABody = 'vless://u@h.example:443?type=ws&security=tls&sni=y#Alpha';
  // Пересохранение без правки: тот же текст. `canonicalNodeBody` — это
  // `emit()`, а он включает `tag`, поэтому переименование узла для этой
  // функции ТОЖЕ смена тела (так же считает refetch подписки — одна функция
  // на один вопрос). Держит вердикт только по-настоящему нетронутое тело.
  const uriASame = 'vless://u@h.example:443?security=tls&type=ws&sni=x#Alpha';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('core_reject_edit_');
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

  Future<SubscriptionController> makeController() async {
    final c = SubscriptionController();
    await c.init();
    return c;
  }

  /// Папка с одним членом, на который страховка уже поставила вердикт.
  Future<SubscriptionController> folderWithVerdict() async {
    final c = await makeController();
    await c.addFolder('F');
    await c.addMembersToFolder(0, uriA);
    final folder = c.entries.single.list as FolderServers;
    final members = [...folder.members];
    members[0] = members[0].copyWith(
      enabled: false,
      warnings: [StoredWarning.coreRejected('parse encryption: bad')],
    );
    await c.replaceList(0, folder.copyWith(members: members));
    return c;
  }

  /// Ручной сервер из [uriA]. Запись ставится `replaceList`, а не остаётся
  /// той, что вернул `addUserServer`: тот прогоняет узел через авто-эмодзи
  /// (§090) и переименовывает его, после чего тело записи перестало бы
  /// совпадать с телом разбора той же ссылки — и проверялась бы §090, а не
  /// вердикт.
  Future<SubscriptionController> serverEntry({
    bool enabled = true,
    List<StoredWarning> warnings = const [],
  }) async {
    final c = await makeController();
    final srv = UserServer(
      id: 'u1',
      name: '',
      enabled: enabled,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      rawBody: uriA,
      warnings: warnings,
      nodes: [parseUri(uriA)!],
    );
    await c.addUserServer(srv);
    await c.replaceList(0, srv);
    return c;
  }

  /// Ручной сервер с вердиктом.
  Future<SubscriptionController> serverWithVerdict() => serverEntry(
        enabled: false,
        warnings: [StoredWarning.coreRejected('parse encryption: bad')],
      );

  group('член папки — updateMemberAt', () {
    test('тело изменилось → вердикт снят, член включён обратно', () async {
      final c = await folderWithVerdict();
      expect(await c.updateMemberAt(0, 0, uriABody), isNull);

      final m = (c.entries.single.list as FolderServers).members.single;
      expect(m.warnings.where((w) => w.isCoreRejected), isEmpty);
      expect(m.enabled, isTrue);
      expect(c.entries.single.nodeCount, 1);
    });

    test('пересохранение без правки (то же тело) вердикт НЕ снимает', () async {
      final c = await folderWithVerdict();
      expect(await c.updateMemberAt(0, 0, uriASame), isNull);

      final m = (c.entries.single.list as FolderServers).members.single;
      expect(m.warnings.single.isCoreRejected, isTrue);
      expect(m.enabled, isFalse);
    });

    test('прочие записи узла переживают снятие вердикта', () async {
      final c = await makeController();
      await c.addFolder('F');
      await c.addMembersToFolder(0, uriA);
      final folder = c.entries.single.list as FolderServers;
      final members = [...folder.members];
      members[0] = members[0].copyWith(enabled: false, warnings: [
        StoredWarning.coreRejected('bad'),
        const StoredWarning(code: 'tls_insecure'),
      ]);
      await c.replaceList(0, folder.copyWith(members: members));

      expect(await c.updateMemberAt(0, 0, uriABody), isNull);
      final m = (c.entries.single.list as FolderServers).members.single;
      expect(m.warnings.map((w) => w.code), ['tls_insecure']);
      expect(m.enabled, isTrue);
    });
  });

  group('ручной сервер — updateConnectionAt', () {
    test('тело изменилось → вердикт снят, сервер включён обратно', () async {
      final c = await serverWithVerdict();
      await c.updateConnectionAt(0, [uriABody]);

      final srv = c.entries.single.list as UserServer;
      expect(srv.warnings.where((w) => w.isCoreRejected), isEmpty);
      expect(srv.enabled, isTrue);
    });

    test('пересохранение без правки (то же тело) вердикт НЕ снимает', () async {
      final c = await serverWithVerdict();
      await c.updateConnectionAt(0, [uriASame]);

      final srv = c.entries.single.list as UserServer;
      expect(srv.warnings.single.isCoreRejected, isTrue);
      expect(srv.enabled, isFalse);
    });

    test('сервер, выключенный человеком (без вердикта), правкой не оживает',
        () async {
      final c = await serverEntry(enabled: false);

      await c.updateConnectionAt(0, [uriABody]);
      expect((c.entries.single.list as UserServer).enabled, isFalse);
    });
  });
}
