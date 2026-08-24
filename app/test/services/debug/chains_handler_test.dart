// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/chains.dart';
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

/// §393 C — `/chains/*` handler поверх реального SettingsStorage
/// (temp-dir через fake path provider, как в directions_handler_test.dart).
void main() {
  late Directory tempDir;

  DebugContext ctx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 8, 24),
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
    tempDir = await Directory.systemTemp.createTemp('chains_handler_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    // Инвариант продукта: vpn-1 существует всегда — цепочка вправе на него
    // сослаться, и тег-коллизия проверяется по обоим спискам сразу.
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

  test('GET /chains — пустой список на чистом storage', () async {
    final r = await chainsHandler(req('GET', '/chains'), ctx());
    expect((r as JsonResponse).body, isEmpty);
  });

  test('POST /chains — первый свободный chain-N + поля тела в один вызов',
      () async {
    final r = await chainsHandler(
      req('POST', '/chains', body: {
        'label': 'Via Germany',
        'hops': ['direct-out', 'vpn-1'],
        'idle_timeout': '30s',
      }),
      ctx(),
    );
    expect((r as JsonResponse).status, 201);
    final body = r.body as Map<String, dynamic>;
    expect(body['tag'], 'chain-1');
    expect(body['label'], 'Via Germany');
    expect(body['hops'], ['direct-out', 'vpn-1']);
    expect(body['idle_timeout'], '30s');

    final stored = await SettingsStorage.getChains();
    expect(stored.single.tag, 'chain-1');
    expect(stored.single.hops, ['direct-out', 'vpn-1']);
  });

  test('POST /chains без тела — пустая цепочка (как в UI: сперва запись)',
      () async {
    final r = await chainsHandler(req('POST', '/chains'), ctx());
    expect(asMap(r)['tag'], 'chain-1');
    expect(asMap(r)['hops'], isEmpty);
    // Второй вызов берёт следующий свободный номер.
    final r2 = await chainsHandler(req('POST', '/chains'), ctx());
    expect(asMap(r2)['tag'], 'chain-2');
  });

  test('POST /chains с кастомным тегом', () async {
    final r = await chainsHandler(
      req('POST', '/chains', body: {'tag': 'home-exit', 'label': 'Home'}),
      ctx(),
    );
    expect(asMap(r)['tag'], 'home-exit');
    expect(asMap(r)['label'], 'Home');
  });

  test('POST /chains с занятым/служебным тегом → 409', () async {
    await chainsHandler(req('POST', '/chains', body: {'tag': 'taken'}), ctx());
    for (final bad in ['taken', 'vpn-1', 'direct-out', 'block', 'vpn-1-auto', '  ']) {
      await expectLater(
        chainsHandler(req('POST', '/chains', body: {'tag': bad}), ctx()),
        throwsA(isA<Conflict>()),
        reason: bad,
      );
    }
  });

  test('GET /chains/{tag} — single + 404 на неизвестный', () async {
    await chainsHandler(req('POST', '/chains'), ctx());
    final r = await chainsHandler(req('GET', '/chains/chain-1'), ctx());
    expect(asMap(r)['tag'], 'chain-1');
    await expectLater(
      chainsHandler(req('GET', '/chains/nope'), ctx()),
      throwsA(isA<NotFound>()),
    );
  });

  group('PATCH /chains/{tag}', () {
    setUp(() async {
      await chainsHandler(
        req('POST', '/chains', body: {
          'hops': ['direct-out', 'vpn-1'],
          'label': 'Route',
        }),
        ctx(),
      );
    });

    test('частичный update не трогает прочие поля', () async {
      final r = await chainsHandler(
        req('PATCH', '/chains/chain-1', body: {'label': 'Renamed'}),
        ctx(),
      );
      expect(asMap(r)['label'], 'Renamed');
      expect(asMap(r)['hops'], ['direct-out', 'vpn-1']);
    });

    test('тег immutable → 400', () async {
      await expectLater(
        chainsHandler(
            req('PATCH', '/chains/chain-1', body: {'tag': 'other'}), ctx()),
        throwsA(isA<BadRequest>()),
      );
    });

    test('404 на неизвестный тег', () async {
      await expectLater(
        chainsHandler(req('PATCH', '/chains/nope', body: {'label': 'x'}), ctx()),
        throwsA(isA<NotFound>()),
      );
    });

    test('strip_evasion трёхзначен: bool / null / отсутствие', () async {
      final off = await chainsHandler(
        req('PATCH', '/chains/chain-1', body: {'strip_evasion': false}), ctx());
      expect(asMap(off)['strip_evasion'], isFalse);
      // Отсутствие ключа — сохранить явный выбор.
      final keep = await chainsHandler(
        req('PATCH', '/chains/chain-1', body: {'label': 'Keep'}), ctx());
      expect(asMap(keep)['strip_evasion'], isFalse);
      // null — вернуть умолчание ядра: ключа в storage-форме больше нет.
      final cleared = await chainsHandler(
        req('PATCH', '/chains/chain-1', body: {'strip_evasion': null}), ctx());
      expect(asMap(cleared).containsKey('strip_evasion'), isFalse);
      final stored = (await SettingsStorage.getChains()).single;
      expect(stored.stripEvasion, isNull);
    });

    test('strip — только ключи каталога, неизвестный → 400', () async {
      final r = await chainsHandler(
        req('PATCH', '/chains/chain-1', body: {
          'strip': {kChainStripTlsUtls: false},
        }),
        ctx(),
      );
      expect((asMap(r)['strip'] as Map)[kChainStripTlsUtls], isFalse);
      await expectLater(
        chainsHandler(
          req('PATCH', '/chains/chain-1', body: {
            'strip': {'tls.nonsense': true},
          }),
          ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
    });

    test('rewrite переживает round-trip дословно (null внутри — значимый)',
        () async {
      final r = await chainsHandler(
        req('PATCH', '/chains/chain-1', body: {
          'rewrite': {
            'vless': {'flow': null, 'packet_encoding': 'xudp'},
          },
        }),
        ctx(),
      );
      final rewrite = (asMap(r)['rewrite'] as Map)['vless'] as Map;
      expect(rewrite.containsKey('flow'), isTrue);
      expect(rewrite['flow'], isNull);
      expect(rewrite['packet_encoding'], 'xudp');
    });
  });

  group('валидация — тот же рубеж, что у формы (§393 L4)', () {
    test('одна позиция → 400 (ядро односкачковую цепочку отвергает)', () async {
      await chainsHandler(req('POST', '/chains'), ctx());
      await expectLater(
        chainsHandler(
          req('PATCH', '/chains/chain-1', body: {
            'hops': ['vpn-1'],
          }),
          ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
      // Отказ не записался: цепочка осталась пустой.
      expect((await SettingsStorage.getChains()).single.hops, isEmpty);
    });

    test('POST с одной позицией тоже отвергается', () async {
      await expectLater(
        chainsHandler(
          req('POST', '/chains', body: {
            'hops': ['vpn-1'],
          }),
          ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
    });

    test('дубль позиции и самоссылка → 400', () async {
      await chainsHandler(req('POST', '/chains'), ctx());
      await expectLater(
        chainsHandler(
          req('PATCH', '/chains/chain-1', body: {
            'hops': ['vpn-1', 'vpn-1'],
          }),
          ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
      await expectLater(
        chainsHandler(
          req('PATCH', '/chains/chain-1', body: {
            'hops': ['direct-out', 'chain-1'],
          }),
          ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
    });

    test('пустая позиция → 400', () async {
      await chainsHandler(req('POST', '/chains'), ctx());
      await expectLater(
        chainsHandler(
          req('PATCH', '/chains/chain-1', body: {
            'hops': ['direct-out', '  '],
          }),
          ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
    });

    test('ссылка на цепочку НИЖЕ по списку → 400 (циклы исключены порядком)',
        () async {
      await chainsHandler(req('POST', '/chains'), ctx()); // chain-1
      await chainsHandler(req('POST', '/chains'), ctx()); // chain-2
      // chain-1 объявлена выше — сослаться на chain-2 она не вправе.
      await expectLater(
        chainsHandler(
          req('PATCH', '/chains/chain-1', body: {
            'hops': ['chain-2', 'vpn-1'],
          }),
          ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
      // Обратная ссылка (вверх) законна.
      final ok = await chainsHandler(
        req('PATCH', '/chains/chain-2', body: {
          'hops': ['chain-1', 'vpn-1'],
        }),
        ctx(),
      );
      expect(asMap(ok)['hops'], ['chain-1', 'vpn-1']);
    });

    test('вложенная цепочка НЕ на позиции 0 → 400', () async {
      await chainsHandler(req('POST', '/chains'), ctx()); // chain-1
      await chainsHandler(req('POST', '/chains'), ctx()); // chain-2
      await expectLater(
        chainsHandler(
          req('PATCH', '/chains/chain-2', body: {
            'hops': ['vpn-1', 'chain-1'],
          }),
          ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
    });
  });

  group('DELETE /chains/{tag}', () {
    test('удаляет; unknown → 404; висячие ссылки перечислены', () async {
      await chainsHandler(req('POST', '/chains'), ctx()); // chain-1
      await chainsHandler(
        req('POST', '/chains', body: {
          'hops': ['chain-1', 'vpn-1'],
        }),
        ctx(),
      ); // chain-2

      final r = await chainsHandler(req('DELETE', '/chains/chain-1'), ctx());
      expect(asMap(r)['ok'], isTrue);
      expect(asMap(r)['dangling_refs'], ['chain-2']);
      final stored = await SettingsStorage.getChains();
      expect(stored.map((c) => c.tag), ['chain-2']);
      // Позиция НЕ вычищена: маршрут без хопа — другой маршрут.
      expect(stored.single.hops, ['chain-1', 'vpn-1']);

      await expectLater(
        chainsHandler(req('DELETE', '/chains/chain-1'), ctx()),
        throwsA(isA<NotFound>()),
      );
    });
  });

  test('?rebuild=true — write доезжает до storage', () async {
    // Контроллеры в тесте не зарегистрированы, поэтому сам rebuild упирается в
    // общий для всех CRUD-хендлеров `requireSub` → Conflict (то же поведение,
    // что у /directions). Проверяем главное: флаг не ломает write — запись уже
    // на диске, а не откатывается вместе с неудачной пересборкой.
    await expectLater(
      chainsHandler(
        req('POST', '/chains',
            body: {
              'hops': ['direct-out', 'vpn-1'],
            },
            query: {'rebuild': 'true'}),
        ctx(),
      ),
      throwsA(isA<Conflict>()),
    );
    final stored = await SettingsStorage.getChains();
    expect(stored.single.tag, 'chain-1');
    expect(stored.single.hops, ['direct-out', 'vpn-1']);

    await expectLater(
      chainsHandler(
        req('DELETE', '/chains/chain-1', query: {'rebuild': 'true'}),
        ctx(),
      ),
      throwsA(isA<Conflict>()),
    );
    expect(await SettingsStorage.getChains(), isEmpty);
  });

  test('?rebuild=false / без флага — обычный ответ', () async {
    final r = await chainsHandler(
      req('POST', '/chains',
          body: {
            'hops': ['direct-out', 'vpn-1'],
          },
          query: {'rebuild': 'false'}),
      ctx(),
    );
    expect((r as JsonResponse).status, 201);
    expect((r.body as Map).containsKey('rebuilt'), isFalse);
  });

  test('неподдержанный метод → 400', () async {
    await expectLater(
      chainsHandler(req('PUT', '/chains'), ctx()),
      throwsA(isA<BadRequest>()),
    );
    await expectLater(
      chainsHandler(req('POST', '/chains/chain-1'), ctx()),
      throwsA(isA<BadRequest>()),
    );
  });
}
