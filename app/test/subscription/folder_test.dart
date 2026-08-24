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

    test('§284 ping_url/ping_timeout_ms: round-trip + copyWith сохраняет', () {
      final f = FolderServers(
        id: 'f-2',
        name: 'WARP GENERATOR',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [FolderMember(raw: uriA)],
        pingUrl: 'https://1.1.1.1/cdn-cgi/trace',
        pingTimeoutMs: 3000,
      );
      // backup-инвариант: поля переживают toJson→fromJson.
      final rt = ServerList.fromJson(f.toJson()) as FolderServers;
      expect(rt.pingUrl, 'https://1.1.1.1/cdn-cgi/trace');
      expect(rt.pingTimeoutMs, 3000);

      // copyWith без ping-аргументов НЕ теряет поля.
      final kept = f.copyWith(members: [FolderMember(raw: uriB)]);
      expect(kept.pingUrl, 'https://1.1.1.1/cdn-cgi/trace');
      expect(kept.pingTimeoutMs, 3000);

      // clearPing сбрасывает в null (→ глобальный ping при тесте).
      final cleared = f.copyWith(clearPing: true);
      expect(cleared.pingUrl, isNull);
      expect(cleared.pingTimeoutMs, isNull);
      expect(cleared.toJson().containsKey('ping_url'), isFalse);

      // Папка без ping-полей → null (берётся глобальное).
      final plain = FolderServers(
        id: 'f-3',
        name: 'Plain',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
      );
      expect(plain.pingUrl, isNull);
      expect((ServerList.fromJson(plain.toJson()) as FolderServers).pingUrl,
          isNull);
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
      expect(err, isNull);

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
      expect(err, isNull);

      final folder = c.entries.single.list as FolderServers;
      expect(folder.members[0].node!.tag, 'proton-nl');
      expect(folder.members[1].node!.tag, 'proton-nl 2');
      // Именованная нода имя файла НЕ получает.
      final err2 =
          await c.addMembersToFolder(0, uriA, nameFallback: 'ignored');
      expect(err2, isNull);
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
      expect(err, isNotNull);
      final folder = c.entries.single.list as FolderServers;
      expect(folder.members.single.raw, uriA);

      final ok = await c.updateMemberAt(0, 0, uriB);
      expect(ok, isNull);
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
      expect(err, isNull);
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
      expect(err, isNull);
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
      expect(err, isNull);
      // Единственная запись — папка (никакой SubscriptionServers).
      expect(c.entries, hasLength(1));
      final folder = c.entries.single.list as FolderServers;
      expect(folder.members, hasLength(2));
      // Персист выжил round-trip (raw самодостаточен).
      final lists = await SettingsStorage.getServerLists();
      final saved = lists.single as FolderServers;
      expect(saved.nodes.map((n) => n.tag), ['Alpha', 'Beta']);
    });

    test('§237 setMemberDetour + detour переживает move/ungroup', () async {
      final c = await makeController();
      await c.addFromInput(uriA);
      // Личный detour одиночного сервера.
      final us = c.entries.single.list as UserServer;
      await c.replaceList(
          0,
          us.copyWith(
              detourPolicy:
                  DetourPolicy.defaults.copyWith(overrideDetour: 'Jump')));
      await c.addFolder('F');

      // Перенос в папку сохраняет личный detour в member.detour.
      await c.moveServerToFolder(0, 1);
      var folder = c.entries.single.list as FolderServers;
      expect(folder.members.single.detour, 'Jump');

      // setMemberDetour меняет и персистит.
      await c.setMemberDetour(0, 0, 'Jump2');
      folder = c.entries.single.list as FolderServers;
      expect(folder.members.single.detour, 'Jump2');
      final saved =
          (await SettingsStorage.getServerLists()).single as FolderServers;
      expect(saved.members.single.detour, 'Jump2');

      // Вынос обратно — detour возвращается в overrideDetour одиночного.
      await c.ungroupMemberAt(0, 0);
      final back = c.entries[1].list as UserServer;
      expect(back.detourPolicy.overrideDetour, 'Jump2');
    });

    test('§239 setMemberDetour: self и цикл отклоняются, интра хранится голым',
        () async {
      final c = await makeController();
      await c.addFolder('F');
      await c.addMembersToFolder(0, '$uriA\n$uriB');

      // self
      expect(await c.setMemberDetour(0, 0, 'Alpha'), isNotNull);
      // интра-ребро A→B ок, хранится голым тегом
      expect(await c.setMemberDetour(0, 0, 'Beta'), isNull);
      var folder = c.entries.single.list as FolderServers;
      expect(folder.members[0].detour, 'Beta');
      // замыкающее B→A — отказ
      expect(await c.setMemberDetour(0, 1, 'Alpha'), isNotNull);
      folder = c.entries.single.list as FolderServers;
      expect(folder.members[1].detour, isEmpty);
    });

    test('§236 setMembersEnabled/removeMembersAt/applyMembersOrder', () async {
      final c = await makeController();
      await c.addFolder('F');
      await c.addMembersToFolder(0, '$uriA\n$uriB\n$uriUnnamed');

      await c.setMembersEnabled(0, {0, 2}, false);
      var folder = c.entries.single.list as FolderServers;
      expect(folder.members.map((m) => m.enabled), [false, true, false]);
      expect(folder.nodes.map((n) => n.tag), ['Beta']);

      // Перестановка: [2,0,1]; кривые перестановки игнорируются.
      await c.applyMembersOrder(0, [2, 0, 1]);
      folder = c.entries.single.list as FolderServers;
      expect(folder.members[1].node!.tag, 'Alpha');
      await c.applyMembersOrder(0, [0, 0, 1]); // дубль — no-op
      await c.applyMembersOrder(0, [0]); // не та длина — no-op
      folder = c.entries.single.list as FolderServers;
      expect(folder.members.length, 3);

      await c.removeMembersAt(0, {0, 2});
      folder = c.entries.single.list as FolderServers;
      expect(folder.members.single.node!.tag, 'Alpha');
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
      // §267 — group_templates: vpn-1 Направление (direct+auto), auto-подгруппа.
      groupTemplates: GroupTemplates(
        direction: DirectionTemplate(
          include: const ['direct', 'auto'],
          options: const {'interrupt_exist_connections': true},
        ),
        auto: AutoTemplate(
          options: const {'url': 'https://x', 'interval': '30s'},
        ),
        defaultDirections: [
          DefaultDirection(tag: 'vpn-1', label: 'vpn-1', defaultEnabled: true),
        ],
      ),
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

    test('§237 личный detour члена + политика папки (use/append/replace/none)',
        () async {
      // Целевые outbound'ы detour'ов — одиночные серверы Jump/Jump2.
      UserServer jump(String tag, String host) => UserServer(
            id: 'u-$tag',
            name: tag,
            enabled: true,
            tagPrefix: '',
            detourPolicy: DetourPolicy.defaults,
            origin: UserSource.manual,
            createdAt: DateTime.now(),
            nodes: [
              parseUri(
                  'vless://ju@$host:443?type=ws&security=tls#$tag')!,
            ],
          );

      FolderServers folderWith(DetourPolicy policy) => FolderServers(
            id: 'f-1',
            name: 'F',
            enabled: true,
            tagPrefix: '',
            detourPolicy: policy,
            members: [
              FolderMember(raw: uriA, detour: 'Jump'), // личный detour
              FolderMember(raw: uriB), // без личного
            ],
          );

      Future<Map<String, String?>> detoursFor(DetourPolicy policy) async {
        final result = await buildConfig(
          lists: [folderWith(policy), jump('Jump', 'j1'), jump('Jump2', 'j2')],
          template: template,
          settings: const BuildSettings(
            userVars: {'clash_api': '127.0.0.1:9090'},
            enabledGroups: {'vpn-1', kAutoOutboundTag},
          ),
        );
        expect(result.validation.isOk, true,
            reason: result.validation.issues.join('\n'));
        final map = <String, String?>{};
        for (final o in (result.config['outbounds'] as List)) {
          final m = o as Map;
          map[m['tag'] as String] = m['detour'] as String?;
        }
        return map;
      }

      // Use (дефолт): личный применяется, без личного — ничего.
      var d = await detoursFor(DetourPolicy.defaults);
      expect(d['Alpha'], 'Jump');
      expect(d['Beta'], isNull);

      // Append (Replace OFF): личный побеждает, папочный — тем, у кого нет.
      d = await detoursFor(const DetourPolicy(overrideDetour: 'Jump2'));
      expect(d['Alpha'], 'Jump');
      expect(d['Beta'], 'Jump2');

      // Replace ON: папочный переписывает всех.
      d = await detoursFor(const DetourPolicy(
          overrideDetour: 'Jump2', replaceDetourChain: true));
      expect(d['Alpha'], 'Jump2');
      expect(d['Beta'], 'Jump2');

      // None: без detour вообще (личный тоже снят).
      d = await detoursFor(const DetourPolicy(useDetourServers: false));
      expect(d['Alpha'], isNull);
      expect(d['Beta'], isNull);
    });

    test('§239 интра-цепочки: append к хвосту, exempt, циклы, register-гейт',
        () async {
      UserServer jump(String tag, String host) => UserServer(
            id: 'u-$tag',
            name: tag,
            enabled: true,
            tagPrefix: '',
            detourPolicy: DetourPolicy.defaults,
            origin: UserSource.manual,
            createdAt: DateTime.now(),
            nodes: [
              parseUri('vless://ju@$host:443?type=ws&security=tls#$tag')!,
            ],
          );

      const uriC = 'vless://u5@h5.example:443?type=ws&security=tls#Gamma';

      Future<
          ({
            Map<String, String?> detours,
            List<String> selector,
          })> run(FolderServers folder) async {
        final result = await buildConfig(
          lists: [folder, jump('Jump', 'j1')],
          template: template,
          settings: const BuildSettings(
            userVars: {'clash_api': '127.0.0.1:9090'},
            enabledGroups: {'vpn-1', kAutoOutboundTag},
          ),
        );
        expect(result.validation.isOk, true,
            reason: result.validation.issues.join('\n'));
        final detours = <String, String?>{};
        for (final o in (result.config['outbounds'] as List)) {
          final m = o as Map;
          detours[m['tag'] as String] = m['detour'] as String?;
        }
        final selectorRaw = ((result.config['outbounds'] as List)
                .firstWhere((o) => (o as Map)['tag'] == 'vpn-1')
            as Map)['outbounds'] as List;
        final selector = selectorRaw.cast<String>();
        return (detours: detours, selector: selector);
      }

      FolderServers folder({
        DetourPolicy policy = DetourPolicy.defaults,
        String aDetour = 'Beta', // интра: голый тег члена B
        String bDetour = '',
      }) =>
          FolderServers(
            id: 'f-1',
            name: 'F',
            enabled: true,
            tagPrefix: 'pr:',
            detourPolicy: policy,
            members: [
              FolderMember(raw: uriA, detour: aDetour),
              FolderMember(raw: uriB, detour: bDetour),
              FolderMember(raw: uriC),
            ],
          );

      // 1. Интра-ссылка резолвится в display; append папки достаётся хвосту
      //    (B без личного) → цепочка A→B→Jump целиком.
      var r = await run(folder(
          policy: const DetourPolicy(overrideDetour: 'Jump')));
      expect(r.detours['pr: Alpha'], 'pr: Beta');
      expect(r.detours['pr: Beta'], 'Jump');
      expect(r.detours['pr: Gamma'], 'Jump');

      // 2. Register-гейт: B (интра-цель) скрыт из селектора по умолчанию…
      expect(r.selector, isNot(contains('pr: Beta')));
      expect(r.selector, contains('pr: Alpha'));
      // …и возвращается тогглом registerDetourServers.
      r = await run(folder(
          policy: const DetourPolicy(
              overrideDetour: 'Jump', registerDetourServers: true)));
      expect(r.selector, contains('pr: Beta'));

      // 3. Папочный override в СВОЕГО члена: exempt-закрытие цели.
      //    override='Alpha' (bare), A личный → B: exempt = {A, B} →
      //    A сохраняет личный, B direct; C → 'pr: Alpha'.
      r = await run(folder(
          policy: const DetourPolicy(overrideDetour: 'Alpha')));
      expect(r.detours['pr: Gamma'], 'pr: Alpha');
      expect(r.detours['pr: Alpha'], 'pr: Beta'); // exempt: личный сохранён
      expect(r.detours['pr: Beta'], isNull); // exempt-хвост: direct

      // 4. Replace ON с интра-целью: все → цель, кроме exempt-цепочки цели.
      r = await run(folder(
          policy: const DetourPolicy(
              overrideDetour: 'Beta', replaceDetourChain: true)));
      expect(r.detours['pr: Alpha'], 'pr: Beta');
      expect(r.detours['pr: Gamma'], 'pr: Beta');
      expect(r.detours['pr: Beta'], isNull); // цель exempt — не сама в себя

      // 5. Цикл из ручного бэкапа рвётся (замыкающее ребро выброшено).
      r = await run(folder(aDetour: 'Beta', bDetour: 'Alpha'));
      expect(r.detours['pr: Alpha'], 'pr: Beta');
      expect(r.detours['pr: Beta'], isNull); // ребро B→A вырезано
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
