// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/channel.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/channels.dart';
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

/// §238 — `/channels/*` handler поверх реального SettingsStorage
/// (temp-dir через fake path provider, как в folder_test.dart).
void main() {
  late Directory tempDir;

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

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('channels_handler_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    // Инвариант продукта: vpn-1 существует всегда (обычно — из миграции).
    await SettingsStorage.setChannels([
      const Channel(tag: 'vpn-1', label: 'VPN ①'),
    ]);
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  test('GET /channels — список storage-shape', () async {
    final r = await channelsHandler(req('GET', '/channels'), ctx());
    final list = (r as JsonResponse).body as List;
    expect(list, hasLength(1));
    expect((list.single as Map)['tag'], 'vpn-1');
  });

  test('POST /channels — первый свободный vpn-N + PATCH-поля в один вызов',
      () async {
    final r = await channelsHandler(
      req('POST', '/channels', body: {
        'label': 'Germany',
        'node_filter': 'DE|Frankfurt',
        'auto': {'interval': '3m'},
      }),
      ctx(),
    );
    expect((r as JsonResponse).status, 201);
    final body = r.body as Map<String, dynamic>;
    expect(body['tag'], 'vpn-2');
    expect(body['label'], 'Germany');
    expect(body['node_filter'], 'DE|Frankfurt');
    expect((body['auto'] as Map)['interval'], '3m');
    // Немодифицированные auto-поля — дефолты, не null.
    expect((body['auto'] as Map)['tolerance'], 50);

    final stored = await SettingsStorage.getChannels();
    expect(stored.map((c) => c.tag), ['vpn-1', 'vpn-2']);
  });

  test('POST /channels — лимит 10 → 409', () async {
    for (var i = 0; i < 9; i++) {
      await channelsHandler(req('POST', '/channels'), ctx());
    }
    expect((await SettingsStorage.getChannels()).length, kMaxChannels);
    await expectLater(
      channelsHandler(req('POST', '/channels'), ctx()),
      throwsA(isA<Conflict>()),
    );
  });

  test('GET /channels/{tag} — single + 404 на неизвестный', () async {
    final r = await channelsHandler(req('GET', '/channels/vpn-1'), ctx());
    expect(asMap(r)['tag'], 'vpn-1');
    await expectLater(
      channelsHandler(req('GET', '/channels/vpn-9'), ctx()),
      throwsA(isA<NotFound>()),
    );
  });

  group('PATCH /channels/{tag}', () {
    test('частичный update не трогает прочие поля', () async {
      await channelsHandler(
          req('POST', '/channels', body: {'node_filter': 'NL'}), ctx());
      final r = await channelsHandler(
        req('PATCH', '/channels/vpn-2', body: {'label': 'Renamed'}),
        ctx(),
      );
      final body = asMap(r);
      expect(body['label'], 'Renamed');
      expect(body['node_filter'], 'NL');
    });

    test('auto — merge, не replace; auto:null снимает галку', () async {
      await channelsHandler(
        req('POST', '/channels', body: {
          'auto': {'url': 'https://ping.example/gen204', 'interval': '9m'},
        }),
        ctx(),
      );
      // Merge: меняем tolerance — url/interval сохраняются.
      final r1 = await channelsHandler(
        req('PATCH', '/channels/vpn-2', body: {
          'auto': {'tolerance': 100},
        }),
        ctx(),
      );
      final auto1 = asMap(r1)['auto'] as Map;
      expect(auto1['url'], 'https://ping.example/gen204');
      expect(auto1['interval'], '9m');
      expect(auto1['tolerance'], 100);

      // Вложенный balancer тоже мержится.
      final r2 = await channelsHandler(
        req('PATCH', '/channels/vpn-2', body: {
          'auto': {
            'mode': 'round_robin',
            'balancer': {'pool': 4},
          },
        }),
        ctx(),
      );
      final auto2 = asMap(r2)['auto'] as Map;
      expect(auto2['mode'], 'round_robin');
      expect((auto2['balancer'] as Map)['pool'], 4);
      expect(auto2['url'], 'https://ping.example/gen204');

      // null — снять галку.
      final r3 = await channelsHandler(
        req('PATCH', '/channels/vpn-2', body: {'auto': null}),
        ctx(),
      );
      expect(asMap(r3)['auto'], isNull);
    });

    test('vpn-1 нельзя выключить → 409', () async {
      await expectLater(
        channelsHandler(
            req('PATCH', '/channels/vpn-1', body: {'enabled': false}), ctx()),
        throwsA(isA<Conflict>()),
      );
    });

    test('tag immutable → 400; битый regex → 400', () async {
      await expectLater(
        channelsHandler(
            req('PATCH', '/channels/vpn-1', body: {'tag': 'vpn-5'}), ctx()),
        throwsA(isA<BadRequest>()),
      );
      await expectLater(
        channelsHandler(
            req('PATCH', '/channels/vpn-1', body: {'node_filter': '('}),
            ctx()),
        throwsA(isA<BadRequest>()),
      );
    });

    test('выключение канала деградирует route_final на vpn-1', () async {
      await channelsHandler(req('POST', '/channels'), ctx());
      await SettingsStorage.saveRouteFinal('vpn-2');
      await channelsHandler(
          req('PATCH', '/channels/vpn-2', body: {'enabled': false}), ctx());
      expect(await SettingsStorage.getRouteFinal(), 'vpn-1');
    });
  });

  group('DELETE /channels/{tag}', () {
    test('удаляет + деградирует ссылки; vpn-1 → 409; unknown → 404', () async {
      await channelsHandler(req('POST', '/channels'), ctx());
      await SettingsStorage.saveRouteFinal('vpn-2');

      final r = await channelsHandler(req('DELETE', '/channels/vpn-2'), ctx());
      expect(asMap(r)['ok'], isTrue);
      expect((await SettingsStorage.getChannels()).map((c) => c.tag), ['vpn-1']);
      expect(await SettingsStorage.getRouteFinal(), 'vpn-1');

      await expectLater(
        channelsHandler(req('DELETE', '/channels/vpn-1'), ctx()),
        throwsA(isA<Conflict>()),
      );
      await expectLater(
        channelsHandler(req('DELETE', '/channels/vpn-2'), ctx()),
        throwsA(isA<NotFound>()),
      );
    });
  });

  group('§248/§274 — detour-роль канала', () {
    test('GET/PATCH roundtrip поля detour', () async {
      await channelsHandler(req('POST', '/channels'), ctx()); // vpn-2
      final r1 = await channelsHandler(
          req('PATCH', '/channels/vpn-2', body: {'detour': true}), ctx());
      expect(asMap(r1)['detour'], isTrue);
      final r2 = await channelsHandler(req('GET', '/channels/vpn-2'), ctx());
      expect(asMap(r2)['detour'], isTrue);
      // Снятие роли — тем же полем.
      final r3 = await channelsHandler(
          req('PATCH', '/channels/vpn-2', body: {'detour': false}), ctx());
      expect(asMap(r3)['detour'], isFalse);
    });

    test('vpn-1 не может стать detour → 409', () async {
      await expectLater(
        channelsHandler(
            req('PATCH', '/channels/vpn-1', body: {'detour': true}), ctx()),
        throwsA(isA<Conflict>()),
      );
    });

    test('detour + include_block в одном body — совместимы (§274)', () async {
      await channelsHandler(req('POST', '/channels'), ctx()); // vpn-2
      final r = await channelsHandler(
        req('PATCH', '/channels/vpn-2',
            body: {'detour': true, 'include_block': true}),
        ctx(),
      );
      expect(asMap(r)['detour'], isTrue);
      expect(asMap(r)['include_block'], isTrue);
      final stored = (await SettingsStorage.getChannels())
          .firstWhere((c) => c.tag == 'vpn-2');
      expect(stored.isDetour, isTrue);
      expect(stored.includeBlock, isTrue);
    });

    test('include_block:true на уже-detour канале — принимается (§274)',
        () async {
      await channelsHandler(
          req('POST', '/channels', body: {'detour': true}), ctx()); // vpn-2
      final r = await channelsHandler(
          req('PATCH', '/channels/vpn-2', body: {'include_block': true}),
          ctx());
      expect(asMap(r)['include_block'], isTrue);
      expect(asMap(r)['detour'], isTrue);
    });

    test('detour:true не трогает сохранённый include_block (§274)', () async {
      // Запрет Q1 снят §274: PATCH одним полем detour не нормализует
      // ранее выставленный include_block — галка выживает.
      await channelsHandler(
          req('POST', '/channels', body: {'include_block': true}), ctx());
      final r = await channelsHandler(
          req('PATCH', '/channels/vpn-2', body: {'detour': true}), ctx());
      expect(asMap(r)['detour'], isTrue);
      expect(asMap(r)['include_block'], isTrue);
      final stored = (await SettingsStorage.getChannels())
          .firstWhere((c) => c.tag == 'vpn-2');
      expect(stored.isDetour, isTrue);
      expect(stored.includeBlock, isTrue);
    });

    test('healed в PATCH: flag-set НЕ лечит rules-ссылки (§274)', () async {
      await channelsHandler(req('POST', '/channels'), ctx()); // vpn-2
      await SettingsStorage.saveRouteFinal('vpn-2');
      final r = await channelsHandler(
          req('PATCH', '/channels/vpn-2', body: {'detour': true}), ctx());
      expect(asMap(r)['healed'], {'rules': 0, 'detours': 0});
      expect(await SettingsStorage.getRouteFinal(), 'vpn-2');
    });

    test('healed в DELETE: rules → vpn-1, detour-ссылки → \'\'', () async {
      await channelsHandler(
          req('POST', '/channels', body: {'detour': true}), ctx()); // vpn-2
      await SettingsStorage.saveRouteFinal('vpn-2'); // Debug API может и так
      await SettingsStorage.saveServerLists([
        UserServer(
          id: 'u1',
          name: 'Solo',
          enabled: true,
          tagPrefix: '',
          detourPolicy: const DetourPolicy(overrideDetour: 'vpn-2'),
          origin: UserSource.paste,
          createdAt: DateTime.now(),
        ),
      ]);

      final r = await channelsHandler(req('DELETE', '/channels/vpn-2'), ctx());
      expect(asMap(r)['healed'], {'rules': 1, 'detours': 1});
      expect(await SettingsStorage.getRouteFinal(), 'vpn-1');
      final solo = (await SettingsStorage.getServerLists()).single;
      expect(solo.detourPolicy.overrideDetour, '');
    });
  });

  group('POST /channels/reorder', () {
    test('переставляет; неполный набор → 400', () async {
      await channelsHandler(req('POST', '/channels'), ctx()); // vpn-2
      await channelsHandler(req('POST', '/channels'), ctx()); // vpn-3

      final r = await channelsHandler(
        req('POST', '/channels/reorder', body: {
          'order': ['vpn-3', 'vpn-1', 'vpn-2'],
        }),
        ctx(),
      );
      expect(asMap(r)['count'], 3);
      expect((await SettingsStorage.getChannels()).map((c) => c.tag),
          ['vpn-3', 'vpn-1', 'vpn-2']);

      await expectLater(
        channelsHandler(
          req('POST', '/channels/reorder', body: {
            'order': ['vpn-1', 'vpn-2'],
          }),
          ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
      await expectLater(
        channelsHandler(
          req('POST', '/channels/reorder', body: {
            'order': ['vpn-1', 'vpn-2', 'vpn-9'],
          }),
          ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
    });
  });
}
