// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/directions.dart';
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

/// §238 — `/directions/*` handler поверх реального SettingsStorage
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
    tempDir = await Directory.systemTemp.createTemp('directions_handler_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    // Инвариант продукта: vpn-1 существует всегда (обычно — из миграции).
    await SettingsStorage.setDirections([
      const Direction(tag: 'vpn-1', label: 'VPN ①'),
    ]);
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  test('GET /directions — список storage-shape', () async {
    final r = await directionsHandler(req('GET', '/directions'), ctx());
    final list = (r as JsonResponse).body as List;
    expect(list, hasLength(1));
    expect((list.single as Map)['tag'], 'vpn-1');
  });

  test('POST /directions — первый свободный vpn-N + PATCH-поля в один вызов',
      () async {
    final r = await directionsHandler(
      req('POST', '/directions', body: {
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

    final stored = await SettingsStorage.getDirections();
    expect(stored.map((c) => c.tag), ['vpn-1', 'vpn-2']);
  });

  test('§393 A3 — POST /directions без лимита: 11-е создаётся', () async {
    for (var i = 0; i < 10; i++) {
      await directionsHandler(req('POST', '/directions'), ctx());
    }
    final stored = await SettingsStorage.getDirections();
    expect(stored.length, kMaxDirections + 1);
    expect(stored.last.tag, 'vpn-11');
    expect(stored.last.label, 'VPN 11'); // кружок-цифра кончилась на ⑩
  });

  test('§393 A3 — POST /directions с кастомным тегом', () async {
    final r = await directionsHandler(
      req('POST', '/directions', body: {'tag': 'ru-exit', 'label': 'Russia'}),
      ctx(),
    );
    expect(asMap(r)['tag'], 'ru-exit');
    expect(asMap(r)['label'], 'Russia');
  });

  test('§393 A3 — POST /directions с занятым/служебным тегом → 409', () async {
    for (final bad in ['vpn-1', 'direct-out', 'block', 'vpn-1-auto', '  ']) {
      await expectLater(
        directionsHandler(req('POST', '/directions', body: {'tag': bad}), ctx()),
        throwsA(isA<Conflict>()),
        reason: bad,
      );
    }
  });

  test('§393 A3 — PATCH тега по-прежнему запрещён (immutable)', () async {
    await expectLater(
      directionsHandler(
          req('PATCH', '/directions/vpn-1', body: {'tag': 'x'}), ctx()),
      throwsA(isA<BadRequest>()),
    );
  });

  test('§393 A3 — include принимается PATCH и POST', () async {
    await directionsHandler(req('POST', '/directions'), ctx()); // vpn-2
    final r = await directionsHandler(
      req('PATCH', '/directions/vpn-2', body: {
        'include': ['vpn-1']
      }),
      ctx(),
    );
    expect(asMap(r)['include'], ['vpn-1']);
    final stored = await SettingsStorage.getDirections();
    expect(stored.firstWhere((c) => c.tag == 'vpn-2').include, ['vpn-1']);
  });

  test('GET /directions/{tag} — single + 404 на неизвестный', () async {
    final r = await directionsHandler(req('GET', '/directions/vpn-1'), ctx());
    expect(asMap(r)['tag'], 'vpn-1');
    await expectLater(
      directionsHandler(req('GET', '/directions/vpn-9'), ctx()),
      throwsA(isA<NotFound>()),
    );
  });

  group('PATCH /directions/{tag}', () {
    test('частичный update не трогает прочие поля', () async {
      await directionsHandler(
          req('POST', '/directions', body: {'node_filter': 'NL'}), ctx());
      final r = await directionsHandler(
        req('PATCH', '/directions/vpn-2', body: {'label': 'Renamed'}),
        ctx(),
      );
      final body = asMap(r);
      expect(body['label'], 'Renamed');
      expect(body['node_filter'], 'NL');
    });

    test('auto — merge, не replace; auto:null снимает галку', () async {
      await directionsHandler(
        req('POST', '/directions', body: {
          'auto': {'url': 'https://ping.example/gen204', 'interval': '9m'},
        }),
        ctx(),
      );
      // Merge: меняем tolerance — url/interval сохраняются.
      final r1 = await directionsHandler(
        req('PATCH', '/directions/vpn-2', body: {
          'auto': {'tolerance': 100},
        }),
        ctx(),
      );
      final auto1 = asMap(r1)['auto'] as Map;
      expect(auto1['url'], 'https://ping.example/gen204');
      expect(auto1['interval'], '9m');
      expect(auto1['tolerance'], 100);

      // Вложенный balancer тоже мержится.
      final r2 = await directionsHandler(
        req('PATCH', '/directions/vpn-2', body: {
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
      final r3 = await directionsHandler(
        req('PATCH', '/directions/vpn-2', body: {'auto': null}),
        ctx(),
      );
      expect(asMap(r3)['auto'], isNull);
    });

    test('vpn-1 нельзя выключить → 409', () async {
      await expectLater(
        directionsHandler(
            req('PATCH', '/directions/vpn-1', body: {'enabled': false}), ctx()),
        throwsA(isA<Conflict>()),
      );
    });

    test('tag immutable → 400; битый regex → 400', () async {
      await expectLater(
        directionsHandler(
            req('PATCH', '/directions/vpn-1', body: {'tag': 'vpn-5'}), ctx()),
        throwsA(isA<BadRequest>()),
      );
      await expectLater(
        directionsHandler(
            req('PATCH', '/directions/vpn-1', body: {'node_filter': '('}),
            ctx()),
        throwsA(isA<BadRequest>()),
      );
    });

    test('выключение Направления деградирует route_final на vpn-1', () async {
      await directionsHandler(req('POST', '/directions'), ctx());
      await SettingsStorage.saveRouteFinal('vpn-2');
      await directionsHandler(
          req('PATCH', '/directions/vpn-2', body: {'enabled': false}), ctx());
      expect(await SettingsStorage.getRouteFinal(), 'vpn-1');
    });
  });

  group('DELETE /directions/{tag}', () {
    test('удаляет + деградирует ссылки; vpn-1 → 409; unknown → 404', () async {
      await directionsHandler(req('POST', '/directions'), ctx());
      await SettingsStorage.saveRouteFinal('vpn-2');

      final r = await directionsHandler(req('DELETE', '/directions/vpn-2'), ctx());
      expect(asMap(r)['ok'], isTrue);
      expect((await SettingsStorage.getDirections()).map((c) => c.tag), ['vpn-1']);
      expect(await SettingsStorage.getRouteFinal(), 'vpn-1');

      await expectLater(
        directionsHandler(req('DELETE', '/directions/vpn-1'), ctx()),
        throwsA(isA<Conflict>()),
      );
      await expectLater(
        directionsHandler(req('DELETE', '/directions/vpn-2'), ctx()),
        throwsA(isA<NotFound>()),
      );
    });
  });

  group('§248/§274 — detour-роль Направления', () {
    test('GET/PATCH roundtrip поля detour', () async {
      await directionsHandler(req('POST', '/directions'), ctx()); // vpn-2
      final r1 = await directionsHandler(
          req('PATCH', '/directions/vpn-2', body: {'detour': true}), ctx());
      expect(asMap(r1)['detour'], isTrue);
      final r2 = await directionsHandler(req('GET', '/directions/vpn-2'), ctx());
      expect(asMap(r2)['detour'], isTrue);
      // Снятие роли — тем же полем.
      final r3 = await directionsHandler(
          req('PATCH', '/directions/vpn-2', body: {'detour': false}), ctx());
      expect(asMap(r3)['detour'], isFalse);
    });

    test('vpn-1 не может стать detour → 409', () async {
      await expectLater(
        directionsHandler(
            req('PATCH', '/directions/vpn-1', body: {'detour': true}), ctx()),
        throwsA(isA<Conflict>()),
      );
    });

    test('detour + include_block в одном body — совместимы (§274)', () async {
      await directionsHandler(req('POST', '/directions'), ctx()); // vpn-2
      final r = await directionsHandler(
        req('PATCH', '/directions/vpn-2',
            body: {'detour': true, 'include_block': true}),
        ctx(),
      );
      expect(asMap(r)['detour'], isTrue);
      expect(asMap(r)['include_block'], isTrue);
      final stored = (await SettingsStorage.getDirections())
          .firstWhere((c) => c.tag == 'vpn-2');
      expect(stored.isDetour, isTrue);
      expect(stored.includeBlock, isTrue);
    });

    test('include_block:true на уже-detour Направлении — принимается (§274)',
        () async {
      await directionsHandler(
          req('POST', '/directions', body: {'detour': true}), ctx()); // vpn-2
      final r = await directionsHandler(
          req('PATCH', '/directions/vpn-2', body: {'include_block': true}),
          ctx());
      expect(asMap(r)['include_block'], isTrue);
      expect(asMap(r)['detour'], isTrue);
    });

    test('detour:true не трогает сохранённый include_block (§274)', () async {
      // Запрет Q1 снят §274: PATCH одним полем detour не нормализует
      // ранее выставленный include_block — галка выживает.
      await directionsHandler(
          req('POST', '/directions', body: {'include_block': true}), ctx());
      final r = await directionsHandler(
          req('PATCH', '/directions/vpn-2', body: {'detour': true}), ctx());
      expect(asMap(r)['detour'], isTrue);
      expect(asMap(r)['include_block'], isTrue);
      final stored = (await SettingsStorage.getDirections())
          .firstWhere((c) => c.tag == 'vpn-2');
      expect(stored.isDetour, isTrue);
      expect(stored.includeBlock, isTrue);
    });

    test('healed в PATCH: flag-set НЕ лечит rules-ссылки (§274)', () async {
      await directionsHandler(req('POST', '/directions'), ctx()); // vpn-2
      await SettingsStorage.saveRouteFinal('vpn-2');
      final r = await directionsHandler(
          req('PATCH', '/directions/vpn-2', body: {'detour': true}), ctx());
      expect(asMap(r)['healed'], {'rules': 0, 'detours': 0, 'includes': 0});
      expect(await SettingsStorage.getRouteFinal(), 'vpn-2');
    });

    test('healed в DELETE: rules → vpn-1, detour-ссылки → \'\'', () async {
      await directionsHandler(
          req('POST', '/directions', body: {'detour': true}), ctx()); // vpn-2
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

      final r = await directionsHandler(req('DELETE', '/directions/vpn-2'), ctx());
      expect(asMap(r)['healed'], {'rules': 1, 'detours': 1, 'includes': 0});
      expect(await SettingsStorage.getRouteFinal(), 'vpn-1');
      final solo = (await SettingsStorage.getServerLists()).single;
      expect(solo.detourPolicy.overrideDetour, '');
    });

    test('§393 A3 — healed.includes в DELETE: тег вычеркнут из include '
        'остальных Направлений', () async {
      await directionsHandler(req('POST', '/directions'), ctx()); // vpn-2
      await directionsHandler(
          req('POST', '/directions', body: {
            'include': ['vpn-2', 'vpn-1']
          }),
          ctx()); // vpn-3

      final r = await directionsHandler(req('DELETE', '/directions/vpn-2'), ctx());
      expect(asMap(r)['healed'], {'rules': 0, 'detours': 0, 'includes': 1});
      final vpn3 = (await SettingsStorage.getDirections())
          .firstWhere((c) => c.tag == 'vpn-3');
      expect(vpn3.include, ['vpn-1']);
    });

    test('§393 A3 — PATCH enabled:false include НЕ трогает (обратимо)',
        () async {
      await directionsHandler(req('POST', '/directions'), ctx()); // vpn-2
      await directionsHandler(
          req('POST', '/directions', body: {
            'include': ['vpn-2']
          }),
          ctx()); // vpn-3

      final r = await directionsHandler(
          req('PATCH', '/directions/vpn-2', body: {'enabled': false}), ctx());
      expect((asMap(r)['healed'] as Map)['includes'], 0);
      final vpn3 = (await SettingsStorage.getDirections())
          .firstWhere((c) => c.tag == 'vpn-3');
      expect(vpn3.include, ['vpn-2']);
    });
  });

  group('POST /directions/reorder', () {
    test('переставляет; неполный набор → 400', () async {
      await directionsHandler(req('POST', '/directions'), ctx()); // vpn-2
      await directionsHandler(req('POST', '/directions'), ctx()); // vpn-3

      final r = await directionsHandler(
        req('POST', '/directions/reorder', body: {
          'order': ['vpn-3', 'vpn-1', 'vpn-2'],
        }),
        ctx(),
      );
      expect(asMap(r)['count'], 3);
      expect((await SettingsStorage.getDirections()).map((c) => c.tag),
          ['vpn-3', 'vpn-1', 'vpn-2']);

      await expectLater(
        directionsHandler(
          req('POST', '/directions/reorder', body: {
            'order': ['vpn-1', 'vpn-2'],
          }),
          ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
      await expectLater(
        directionsHandler(
          req('POST', '/directions/reorder', body: {
            'order': ['vpn-1', 'vpn-2', 'vpn-9'],
          }),
          ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
    });
  });

  /// §275 — зеркальный ресинк `_entries` контроллера после storage-heal
  /// detour-ссылок. Storage лечится сам; без ресинка следующий `_persist()`
  /// воскресил бы вылеченную ссылку на диске (heal показан юзеру и отменён).
  /// Мутации идут через `DirectionMutations`, поэтому разделить heal и ресинк
  /// хендлер не может — тесты пиннят это поведение на всех трёх глаголах.
  group('§275 — detour-ресинк контроллера', () {
    /// Одиночка со stale `overrideDetour` на [tag] + rawBody (без него
    /// `entries` контроллера пусты — нода не парсится).
    UserServer soloWithDetour(String tag) => UserServer(
          id: 'u1',
          name: 'Solo',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy(overrideDetour: tag),
          origin: UserSource.paste,
          createdAt: DateTime.now(),
          rawBody: 'vless://u-a@h.com:443?type=ws&security=tls#solo-node',
        );

    /// Контроллер, поднятый на том же temp-storage и вложенный в registry —
    /// хендлер берёт его из `ctx.registry.sub`.
    Future<SubscriptionController> seedControllerWithStaleRef(String tag) async {
      await SettingsStorage.saveServerLists([soloWithDetour(tag)]);
      final c = SubscriptionController();
      await c.init();
      expect(c.entries.single.list.detourPolicy.overrideDetour, tag,
          reason: 'stale-ссылка должна доехать до in-memory entries');
      DebugRegistry.I.sub = c;
      addTearDown(() => DebugRegistry.I.sub = null);
      return c;
    }

    test('POST /directions: heal при enabled:false зеркалится в entries',
        () async {
      // Сценарий restore из backup: ссылка на vpn-2 есть, самого Направления нет.
      final c = await seedControllerWithStaleRef('vpn-2');

      // POST с PATCH-полем enabled:false → disabling-переход → heal обоих
      // родов ссылок. Это достижимый путь до detours > 0 на создании.
      final r = await directionsHandler(
          req('POST', '/directions', body: {'enabled': false}), ctx());
      expect(asMap(r)['healed'], {'rules': 0, 'detours': 1, 'includes': 0});

      // Storage вылечен...
      final solo = (await SettingsStorage.getServerLists()).single;
      expect(solo.detourPolicy.overrideDetour, '');
      // ...и зеркало контроллера тоже — иначе _persist воскресит ссылку.
      expect(c.entries.single.list.detourPolicy.overrideDetour, '',
          reason: 'без ресинка следующий _persist воскресил бы vpn-2');
    });

    test('POST /directions: _persist после ресинка не воскрешает ссылку',
        () async {
      final c = await seedControllerWithStaleRef('vpn-2');
      await directionsHandler(
          req('POST', '/directions', body: {'enabled': false}), ctx());

      // Любая контроллерная мутация с _persist пишет entries на диск.
      await c.renameAt(0, 'Solo Renamed');
      SettingsStorage.resetCacheForTesting(); // читаем реально с диска
      final saved = (await SettingsStorage.getServerLists()).single;
      expect(saved.name, 'Solo Renamed');
      expect(saved.detourPolicy.overrideDetour, '',
          reason: '_persist после ресинка не должен воскрешать ссылку');
    });

    test('PATCH /directions/{tag}: flag-unset зеркалится в entries', () async {
      await directionsHandler(
          req('POST', '/directions', body: {'detour': true}), ctx()); // vpn-2
      final c = await seedControllerWithStaleRef('vpn-2');

      final r = await directionsHandler(
          req('PATCH', '/directions/vpn-2', body: {'detour': false}), ctx());
      expect(asMap(r)['healed'], {'rules': 0, 'detours': 1, 'includes': 0});
      expect(c.entries.single.list.detourPolicy.overrideDetour, '');
    });

    test('DELETE /directions/{tag}: heal зеркалится в entries', () async {
      await directionsHandler(
          req('POST', '/directions', body: {'detour': true}), ctx()); // vpn-2
      final c = await seedControllerWithStaleRef('vpn-2');

      final r = await directionsHandler(req('DELETE', '/directions/vpn-2'), ctx());
      expect(asMap(r)['healed'], {'rules': 0, 'detours': 1, 'includes': 0});
      expect(c.entries.single.list.detourPolicy.overrideDetour, '');
    });

    test('sub == null (UI не готов): heal storage без падения', () async {
      await SettingsStorage.saveServerLists([soloWithDetour('vpn-2')]);
      expect(DebugRegistry.I.sub, isNull);

      final r = await directionsHandler(
          req('POST', '/directions', body: {'enabled': false}), ctx());
      expect(asMap(r)['healed'], {'rules': 0, 'detours': 1, 'includes': 0});
      final solo = (await SettingsStorage.getServerLists()).single;
      expect(solo.detourPolicy.overrideDetour, '',
          reason: 'без контроллера нет и entries, которые разъезжаются');
    });
  });
}
