// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/folders.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
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

/// §238 — `/folders/*` handler поверх реального SubscriptionController
/// (temp-dir через fake path provider, как в folder_test.dart). Probe не
/// покрыт — требует native CcChannel (device-verify).
void main() {
  late Directory tempDir;
  late SubscriptionController controller;

  const uriA = 'vless://u1@h1.example:443?type=ws&security=tls#Alpha';
  const uriB = 'vless://u2@h2.example:443?type=ws&security=tls#Beta';

  DebugContext ctx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 7, 4),
      );

  DebugRequest req(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String> query = const {},
  }) =>
      DebugRequest.forTest(
        method: method,
        path: path,
        query: query,
        body: body == null ? const [] : utf8.encode(jsonEncode(body)),
      );

  Map<String, dynamic> asMap(DebugResponse r) =>
      (r as JsonResponse).body as Map<String, dynamic>;

  Future<String> createFolder(String name) async {
    final r = await foldersHandler(
        req('POST', '/folders', body: {'name': name}), ctx());
    expect((r as JsonResponse).status, 201);
    return (r.body as Map<String, dynamic>)['id'] as String;
  }

  Future<Map<String, dynamic>> getFolder(String id,
      {bool reveal = false}) async {
    final r = await foldersHandler(
      req('GET', '/folders/$id',
          query: reveal ? {'reveal': 'true'} : const {}),
      ctx(),
    );
    return asMap(r);
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('folders_handler_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    controller = SubscriptionController();
    await controller.init();
    DebugRegistry.I.sub = controller;
  });

  tearDown(() async {
    DebugRegistry.I.sub = null;
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  test('POST /folders → 201; GET /folders — только папки', () async {
    final id = await createFolder('Proton');
    expect(id, isNotEmpty);

    // Одиночный сервер в общем списке /folders не отображается.
    await controller.addFromInput(uriA);

    final r = await foldersHandler(req('GET', '/folders'), ctx());
    final list = (r as JsonResponse).body as List;
    expect(list, hasLength(1));
    final folder = list.single as Map;
    expect(folder['id'], id);
    expect(folder['kind'], 'FolderServers');
    expect(folder['members'], isEmpty);
  });

  test('POST /folders без имени → 400', () async {
    await expectLater(
      foldersHandler(req('POST', '/folders', body: {'name': '  '}), ctx()),
      throwsA(isA<BadRequest>()),
    );
  });

  test('не-папка по id → 409, неизвестный id → 404', () async {
    await controller.addFromInput(uriA);
    final serverId = controller.entries.single.id;
    await expectLater(
      foldersHandler(req('GET', '/folders/$serverId'), ctx()),
      throwsA(isA<Conflict>()),
    );
    await expectLater(
      foldersHandler(req('GET', '/folders/nope'), ctx()),
      throwsA(isA<NotFound>()),
    );
  });

  test('POST members (paste) — сплит 1:1; raw скрыт без reveal', () async {
    final id = await createFolder('F');
    final r = await foldersHandler(
      req('POST', '/folders/$id/members', body: {'input': '$uriA\n$uriB'}),
      ctx(),
    );
    expect((r as JsonResponse).status, 201);
    final body = r.body as Map<String, dynamic>;
    expect(body['added'], 2);
    final members = (body['folder'] as Map)['members'] as List;
    expect(members, hasLength(2));
    expect((members[0] as Map)['tag'], 'Alpha');
    expect((members[0] as Map).containsKey('raw'), isFalse);

    final revealed = await getFolder(id, reveal: true);
    expect(((revealed['members'] as List)[0] as Map)['raw'], uriA);
  });

  test('POST members — input и url одновременно / ни одного → 400', () async {
    final id = await createFolder('F');
    await expectLater(
      foldersHandler(
        req('POST', '/folders/$id/members',
            body: {'input': uriA, 'url': 'https://x'}),
        ctx(),
      ),
      throwsA(isA<BadRequest>()),
    );
    await expectLater(
      foldersHandler(req('POST', '/folders/$id/members'), ctx()),
      throwsA(isA<BadRequest>()),
    );
  });

  test('PATCH member: enabled / detour / raw; битый raw → 400', () async {
    final id = await createFolder('F');
    await foldersHandler(
      req('POST', '/folders/$id/members', body: {'input': '$uriA\n$uriB'}),
      ctx(),
    );

    final r1 = await foldersHandler(
      req('PATCH', '/folders/$id/members/0', body: {'enabled': false}),
      ctx(),
    );
    expect((asMap(r1)['member'] as Map)['enabled'], isFalse);

    final r2 = await foldersHandler(
      req('PATCH', '/folders/$id/members/1', body: {'detour': 'jump-de'}),
      ctx(),
    );
    expect((asMap(r2)['member'] as Map)['detour'], 'jump-de');

    await expectLater(
      foldersHandler(
        req('PATCH', '/folders/$id/members/0', body: {'raw': 'garbage'}),
        ctx(),
      ),
      throwsA(isA<BadRequest>()),
    );
    // Пустое body — тоже 400.
    await expectLater(
      foldersHandler(req('PATCH', '/folders/$id/members/0'), ctx()),
      throwsA(isA<BadRequest>()),
    );
    // Индекс вне диапазона → 404.
    await expectLater(
      foldersHandler(
        req('PATCH', '/folders/$id/members/5', body: {'enabled': true}),
        ctx(),
      ),
      throwsA(isA<NotFound>()),
    );
  });

  test('DELETE member + reorder (полная перестановка)', () async {
    final id = await createFolder('F');
    await foldersHandler(
      req('POST', '/folders/$id/members', body: {'input': '$uriA\n$uriB'}),
      ctx(),
    );

    final r = await foldersHandler(
      req('POST', '/folders/$id/members/reorder', body: {
        'order': [1, 0],
      }),
      ctx(),
    );
    final members = ((asMap(r)['folder'] as Map)['members'] as List);
    expect((members[0] as Map)['tag'], 'Beta');

    await expectLater(
      foldersHandler(
        req('POST', '/folders/$id/members/reorder', body: {
          'order': [0, 0],
        }),
        ctx(),
      ),
      throwsA(isA<BadRequest>()),
    );

    final r2 = await foldersHandler(
        req('DELETE', '/folders/$id/members/0'), ctx());
    final left = ((asMap(r2)['folder'] as Map)['members'] as List);
    expect(left, hasLength(1));
    expect((left.single as Map)['tag'], 'Alpha');
  });

  test('ungroup — член становится одиночным сервером после папки', () async {
    final id = await createFolder('F');
    await foldersHandler(
      req('POST', '/folders/$id/members', body: {'input': '$uriA\n$uriB'}),
      ctx(),
    );
    final r = await foldersHandler(
        req('POST', '/folders/$id/members/0/ungroup'), ctx());
    final body = asMap(r);
    expect(body['server_id'], isNotNull);
    expect(((body['folder'] as Map)['members'] as List), hasLength(1));

    final created = controller.entries
        .where((e) => e.id == body['server_id'])
        .single;
    expect(created.list, isA<UserServer>());
    expect(created.list.nodes.single.tag, 'Alpha');
  });

  test('move member в другую папку', () async {
    final a = await createFolder('A');
    final b = await createFolder('B');
    await foldersHandler(
      req('POST', '/folders/$a/members', body: {'input': uriA}),
      ctx(),
    );
    final r = await foldersHandler(
      req('POST', '/folders/$a/members/0/move', body: {'to': b}),
      ctx(),
    );
    final target = asMap(r)['folder'] as Map;
    expect(target['id'], b);
    expect((target['members'] as List), hasLength(1));
    expect((await getFolder(a))['members'], isEmpty);
  });

  test('move-server — одиночный сервер въезжает членом, запись исчезает',
      () async {
    final id = await createFolder('F');
    await controller.addFromInput(uriA);
    final serverId =
        controller.entries.where((e) => e.list is UserServer).single.id;

    final r = await foldersHandler(
      req('POST', '/folders/$id/move-server', body: {'server_id': serverId}),
      ctx(),
    );
    final folder = asMap(r)['folder'] as Map;
    expect((folder['members'] as List), hasLength(1));
    // addFromInput декорирует tag эмодзи протокола — сверяем по вхождению.
    expect(((folder['members'] as List).single as Map)['tag'],
        contains('Alpha'));
    expect(controller.entries.any((e) => e.id == serverId), isFalse);

    // Папку в папку двигать нельзя → 409 (после пред-проверок контроллер
    // отвечает "Only single servers can be moved").
    final other = await createFolder('G');
    await expectLater(
      foldersHandler(
        req('POST', '/folders/$id/move-server', body: {'server_id': other}),
        ctx(),
      ),
      throwsA(isA<Conflict>()),
    );
  });

  test('DELETE /folders/{id} — keep_servers выносит членов одиночными',
      () async {
    final id = await createFolder('F');
    await foldersHandler(
      req('POST', '/folders/$id/members', body: {'input': '$uriA\n$uriB'}),
      ctx(),
    );
    final r = await foldersHandler(
      req('DELETE', '/folders/$id', query: {'keep_servers': 'true'}),
      ctx(),
    );
    expect(asMap(r)['keep_servers'], isTrue);
    expect(controller.entries, hasLength(2));
    expect(controller.entries.every((e) => e.list is UserServer), isTrue);

    // Без keep_servers — совсем.
    final id2 = await createFolder('G');
    await foldersHandler(
      req('POST', '/folders/$id2/members', body: {'input': uriA}),
      ctx(),
    );
    await foldersHandler(req('DELETE', '/folders/$id2'), ctx());
    expect(controller.entries.any((e) => e.id == id2), isFalse);
    expect(controller.entries, hasLength(2)); // прежние два одиночных
  });
}
