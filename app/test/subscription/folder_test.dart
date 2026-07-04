// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
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

/// §234 — папки серверов: модель (members ↔ nodes), операции контроллера
/// (состав, перенос, вынос, снапшот по URL) и сборка конфига.
void main() {
  late Directory tempDir;

  const uriA = 'vless://u1@h1.example:443?type=ws&security=tls#Alpha';
  const uriB = 'vless://u2@h2.example:443?type=ws&security=tls#Beta';
  const uriUnnamed = 'vless://u3@h3.example:443?type=ws&security=tls';
  const uriUnnamed2 = 'vless://u4@h4.example:443?type=ws&security=tls';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('folder_');
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

  group('§234 FolderServers model', () {
    test('JSON round-trip: members, enabled-флаги, created_at', () {
      final original = FolderServers(
        id: 'f-1',
        name: 'Proton',
        enabled: true,
        tagPrefix: 'pr-',
        detourPolicy: const DetourPolicy(overrideDetour: 'jump-1'),
        createdAt: DateTime.utc(2026, 7, 4),
        members: [
          FolderMember(raw: uriA),
          FolderMember(raw: uriB, enabled: false),
        ],
      );

      final j = original.toJson();
      expect(j['type'], 'folder');

      final rt = ServerList.fromJson(j) as FolderServers;
      expect(rt.id, 'f-1');
      expect(rt.name, 'Proton');
      expect(rt.tagPrefix, 'pr-');
      expect(rt.detourPolicy, original.detourPolicy);
      expect(rt.createdAt, original.createdAt);
      expect(rt.members, hasLength(2));
      expect(rt.members[0].raw, uriA);
      expect(rt.members[0].enabled, isTrue);
      expect(rt.members[1].enabled, isFalse);
    });

    test('nodes = только включённые члены (builder-контракт)', () {
      final folder = FolderServers(
        id: 'f-1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(raw: uriA),
          FolderMember(raw: uriB, enabled: false),
        ],
      );
      expect(folder.nodes, hasLength(1));
      expect(folder.nodes.single.tag, 'Alpha');
      expect(folder.disabledCount, 1);
    });

    test('битый raw → node null, член переживает round-trip', () {
      final folder = FolderServers(
        id: 'f-1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [FolderMember(raw: 'garbage-not-a-config')],
      );
      expect(folder.members.single.node, isNull);
      expect(folder.nodes, isEmpty);

      final rt = ServerList.fromJson(folder.toJson()) as FolderServers;
      expect(rt.members.single.raw, 'garbage-not-a-config');
      expect(rt.members.single.node, isNull);
    });
  });

  group('§234 folder ops (controller)', () {
    Future<SubscriptionController> makeController() async {
      final c = SubscriptionController();
      await c.init();
      return c;
    }

    test('addFolder + addMembersToFolder: вход сплитится на членов 1:1',
        () async {
      final c = await makeController();
      await c.addFolder('Proton');
      expect(c.entries.single.list, isA<FolderServers>());

      final err = await c.addMembersToFolder(0, '$uriA\n$uriB');
      expect(err, isEmpty);

      final folder = c.entries.single.list as FolderServers;
      expect(folder.members, hasLength(2));
      expect(folder.members[0].node!.tag, 'Alpha');
      expect(folder.members[1].node!.tag, 'Beta');
      // Каждый член — самодостаточный фрагмент, не всё тело.
      expect(folder.members[0].raw, contains('u1@h1.example'));
      expect(folder.members[0].raw, isNot(contains('u2@h2.example')));
    });

    test('nameFallback: безымянные ноды получают имя файла + суффикс коллизии',
        () async {
      final c = await makeController();
      await c.addFolder('F');
      final err = await c.addMembersToFolder(0, '$uriUnnamed\n$uriUnnamed2',
          nameFallback: 'proton-nl');
      expect(err, isEmpty);

      final folder = c.entries.single.list as FolderServers;
      expect(folder.members[0].node!.tag, 'proton-nl');
      expect(folder.members[1].node!.tag, 'proton-nl 2');
      // Именованная нода имя файла НЕ получает.
      final err2 =
          await c.addMembersToFolder(0, uriA, nameFallback: 'ignored');
      expect(err2, isEmpty);
      final folder2 = c.entries.single.list as FolderServers;
      expect(folder2.members[2].node!.tag, 'Alpha');
    });

    test('toggleMemberAt выключает ноду члена из nodes', () async {
      final c = await makeController();
      await c.addFolder('F');
      await c.addMembersToFolder(0, '$uriA\n$uriB');
      await c.toggleMemberAt(0, 1);

      final folder = c.entries.single.list as FolderServers;
      expect(folder.members[1].enabled, isFalse);
      expect(folder.nodes.map((n) => n.tag), ['Alpha']);
      expect(c.entries.single.nodeCount, 1);
    });

    test('updateMemberAt: битый raw → откат с ошибкой, член не тронут',
        () async {
      final c = await makeController();
      await c.addFolder('F');
      await c.addMembersToFolder(0, uriA);

      final err = await c.updateMemberAt(0, 0, 'not-a-valid-config');
      expect(err, isNotEmpty);
      final folder = c.entries.single.list as FolderServers;
      expect(folder.members.single.raw, uriA);

      final ok = await c.updateMemberAt(0, 0, uriB);
      expect(ok, isEmpty);
      final folder2 = c.entries.single.list as FolderServers;
      expect(folder2.members.single.node!.tag, 'Beta');
    });

    test('deleteFolderAt(keepServers: true) выносит членов одиночными',
        () async {
      final c = await makeController();
      await c.addFolder('F');
      await c.addMembersToFolder(0, '$uriA\n$uriB');
      await c.toggleMemberAt(0, 1); // Beta off

      await c.deleteFolderAt(0, keepServers: true);
      expect(c.entries, hasLength(2));
      final a = c.entries[0].list as UserServer;
      final b = c.entries[1].list as UserServer;
      expect(a.nodes.single.tag, 'Alpha');
      expect(a.enabled, isTrue);
      expect(b.nodes.single.tag, 'Beta');
      expect(b.enabled, isFalse); // per-member toggle сохранён
    });

    test('deleteFolderAt(keepServers: false) удаляет всё', () async {
      final c = await makeController();
      await c.addFolder('F');
      await c.addMembersToFolder(0, uriA);
      await c.deleteFolderAt(0, keepServers: false);
      expect(c.entries, isEmpty);
    });

    test('ungroupMemberAt → одиночный сервер сразу после папки', () async {
      final c = await makeController();
      await c.addFolder('F');
      await c.addMembersToFolder(0, '$uriA\n$uriB');
      await c.ungroupMemberAt(0, 0);

      expect(c.entries, hasLength(2));
      final folder = c.entries[0].list as FolderServers;
      expect(folder.members.single.node!.tag, 'Beta');
      final standalone = c.entries[1].list as UserServer;
      expect(standalone.nodes.single.tag, 'Alpha');
      // Личные настройки папки НЕ наследуются.
      expect(standalone.tagPrefix, isEmpty);
      expect(standalone.detourPolicy, DetourPolicy.defaults);
    });

    test('moveServerToFolder: одиночный сервер становится членом, '
        'личные prefix/policy отброшены', () async {
      final c = await makeController();
      await c.addFromInput(uriA);
      expect(c.entries.single.list, isA<UserServer>());
      // Личный префикс, который должен быть отброшен при переносе.
      c.entries.single.tagPrefix = 'my-';
      await c.persistSources();
      await c.addFolder('F');

      final err = await c.moveServerToFolder(0, 1);
      expect(err, isEmpty);
      expect(c.entries, hasLength(1));
      final folder = c.entries.single.list as FolderServers;
      // addFromInput добавил авто-эмодзи (§090) — сверяем по суффиксу.
      expect(folder.members.single.node!.tag, endsWith('Alpha'));
      expect(folder.tagPrefix, isEmpty); // папочный prefix, не серверный
    });

    test('moveMemberToFolder переносит члена между папками', () async {
      final c = await makeController();
      await c.addFolder('A');
      await c.addFolder('B');
      await c.addMembersToFolder(0, '$uriA\n$uriB');

      final err = await c.moveMemberToFolder(0, 0, 1);
      expect(err, isEmpty);
      final a = c.entries[0].list as FolderServers;
      final b = c.entries[1].list as FolderServers;
      expect(a.members.single.node!.tag, 'Beta');
      expect(b.members.single.node!.tag, 'Alpha');
    });

    test('reorderMember меняет порядок членов', () async {
      final c = await makeController();
      await c.addFolder('F');
      await c.addMembersToFolder(0, '$uriA\n$uriB');
      await c.reorderMember(0, 1, 0);
      final folder = c.entries.single.list as FolderServers;
      expect(folder.members.map((m) => m.node!.tag), ['Beta', 'Alpha']);
    });

    test('addUrlSnapshotToFolder: fetch один раз, подписка НЕ создаётся',
        () async {
      final c = await makeController();
      c.httpClientForTesting = MockClient(
          (req) async => http.Response('$uriA\n$uriB', 200, headers: {
                'profile-update-interval': '12',
              }));
      await c.addFolder('F');

      final err =
          await c.addUrlSnapshotToFolder(0, 'https://example.com/sub');
      expect(err, isEmpty);
      // Единственная запись — папка (никакой SubscriptionServers).
      expect(c.entries, hasLength(1));
      final folder = c.entries.single.list as FolderServers;
      expect(folder.members, hasLength(2));
      // Персист выжил round-trip (raw самодостаточен).
      final lists = await SettingsStorage.getServerLists();
      final saved = lists.single as FolderServers;
      expect(saved.nodes.map((n) => n.tag), ['Alpha', 'Beta']);
    });

    test('rename/toggle папки через общие пути контроллера', () async {
      final c = await makeController();
      await c.addFolder('Old');
      await c.renameAt(0, 'New');
      expect(c.entries.single.name, 'New');
      await c.toggleAt(0);
      expect(c.entries.single.enabled, isFalse);
      expect((c.entries.single.list as FolderServers).name, 'New');
    });
  });

  group('§234 buildConfig с папкой', () {
    final template = WizardTemplate(
      parserConfig: ParserConfigBlock(),
      presetGroups: [
        PresetGroup(
          tag: 'vpn-1',
          type: 'selector',
          options: {'default': kAutoOutboundTag},
          defaultEnabled: true,
          addOutbounds: ['direct-out', kAutoOutboundTag],
        ),
        PresetGroup(
          tag: kAutoOutboundTag,
          type: 'urltest',
          options: {'url': 'https://x', 'interval': '30s'},
          defaultEnabled: true,
          addOutbounds: const [],
        ),
      ],
      vars: const [],
      varSections: const [],
      config: {
        'outbounds': [
          {'tag': 'direct-out', 'type': 'direct'},
        ],
        'route': {'rules': []},
      },
      selectableRules: const [],
      dnsOptions: const {},
      pingOptions: const {},
      speedTestOptions: const {},
    );

    List<String> outboundTags(BuildResult r) =>
        ((r.config['outbounds'] as List?) ?? const [])
            .map((o) => (o as Map)['tag'] as String)
            .toList();

    test('включённые члены эмитятся с префиксом папки, выключенный — нет',
        () async {
      final folder = FolderServers(
        id: 'f-1',
        name: 'Proton',
        enabled: true,
        tagPrefix: 'pr:',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(raw: uriA),
          FolderMember(raw: uriB, enabled: false),
        ],
      );

      final result = await buildConfig(
        lists: [folder],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
          enabledGroups: {'vpn-1', kAutoOutboundTag},
        ),
      );

      expect(result.validation.isOk, true,
          reason: result.validation.issues.join('\n'));
      final tags = outboundTags(result);
      expect(tags, contains('pr: Alpha'));
      expect(tags.where((t) => t.contains('Beta')), isEmpty);
    });

    test('выключенная папка не эмитит ничего', () async {
      final folder = FolderServers(
        id: 'f-1',
        name: 'Proton',
        enabled: false,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [FolderMember(raw: uriA)],
      );

      final result = await buildConfig(
        lists: [folder],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
          enabledGroups: {'vpn-1', kAutoOutboundTag},
        ),
      );

      final tags = outboundTags(result);
      expect(tags.where((t) => t.contains('Alpha')), isEmpty);
    });
  });
}
