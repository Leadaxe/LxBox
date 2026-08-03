// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/import_rule.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/subs.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/subscription_identity.dart';
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

/// §346 — `PATCH /subs/{id}` (identity §289 / on_update_action §323 /
/// import_rules_enabled §302) + под-CRUD `/subs/{id}/rules` поверх реального
/// SubscriptionController (temp-dir через fake path provider, как в
/// folders_handler_test.dart).
///
/// Сетевой фетч не покрыт (нужна живая подписка) — проверяется, что настройки
/// доезжают до модели и персистятся; применение identity к HTTP-заголовкам
/// живёт в §289 и device-verify.
void main() {
  late Directory tempDir;
  late SubscriptionController controller;

  const uriA = 'vless://u1@h1.example:443?type=ws&security=tls#Alpha';
  const uriB = 'vless://u2@h2.example:443?type=ws&security=tls#Beta';

  DebugContext ctx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 8, 2),
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

  /// Подписка (не UserServer) без сети: file-подписка §129 — настоящая
  /// `SubscriptionServers` в списке, но с `url: file:<uuid>`, поэтому фетча
  /// нет. Требует ≥2 узла в теле (иначе контроллер считает её одиночной).
  Future<String> createSub() async {
    final ok = await controller.addFileSubscription('$uriA\n$uriB', 'test.txt');
    expect(ok, isTrue);
    return controller.entries
        .lastWhere((e) => e.list is SubscriptionServers)
        .id;
  }

  Future<Map<String, dynamic>> patch(
    String id,
    Map<String, dynamic> body,
  ) async =>
      asMap(await subsHandler(req('PATCH', '/subs/$id', body: body), ctx()));

  Future<Map<String, dynamic>> rulesList(String id) async =>
      asMap(await subsHandler(req('GET', '/subs/$id/rules'), ctx()));

  /// Правило-образец: `tag contains X → Disable`.
  Map<String, dynamic> disableRule(String needle) => {
        'conditions': [
          {'path': 'tag', 'op': 'contains', 'pattern': needle},
        ],
        'action': 'disable',
      };

  SubscriptionServers listOf(String id) =>
      controller.entries.firstWhere((e) => e.id == id).list
          as SubscriptionServers;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('subs_rules_handler_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    controller = SubscriptionController();
    await controller.init();
    DebugRegistry.I.sub = controller;
    // §289 — глобальная идентичность как «до»-состояние для тестов Custom.
    SubscriptionIdentity.apply(
      userAgentOverride: '',
      sendHwid: false,
      hwid: '',
    );
  });

  tearDown(() async {
    DebugRegistry.I.sub = null;
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  // ─────────────────────────── identity (§289) ───────────────────────────

  test('identity: объект включает Custom, патчит поверх снапшота глобальных',
      () async {
    final id = await createSub();
    SubscriptionIdentity.apply(userAgentOverride: 'Global-UA/1.0');

    expect(asMap(await subsHandler(req('GET', '/subs/$id'), ctx()))['identity'],
        isNull,
        reason: 'по умолчанию режим Default');

    final r = await patch(id, {
      'identity': {'send_hwid': true, 'hwid': 'uuid-1'},
    });

    final identity = r['identity'] as Map<String, dynamic>;
    expect(identity['send_hwid'], true);
    expect(identity['hwid'], 'uuid-1');
    // Ключевое: частичный объект — патч, а не полная замена. UA приехал из
    // снапшота глобальных, хотя в body его не было.
    expect(identity['user_agent'], 'Global-UA/1.0');
  });

  test('identity: null возвращает в Default; глобальные не мутируются',
      () async {
    final id = await createSub();
    await patch(id, {
      'identity': {'send_hwid': true, 'hwid': 'uuid-1'},
    });
    expect(listOf(id).identity, isNotNull);

    final r = await patch(id, {'identity': null});
    expect(r['identity'], isNull);
    expect(listOf(id).identity, isNull);

    // Per-subscription override не трогает глобальную идентичность §118 —
    // ровно то, ради чего таска и делалась.
    expect(SubscriptionIdentity.sendHwid, false);
    expect(SubscriptionIdentity.hwid, '');
  });

  test('identity: повторный патч не сбрасывает уже заданные поля', () async {
    final id = await createSub();
    await patch(id, {
      'identity': {'send_hwid': true, 'hwid': 'uuid-1'},
    });
    await patch(id, {
      'identity': {'device_model': 'Pixel'},
    });

    final identity = listOf(id).identity!;
    expect(identity.hwid, 'uuid-1');
    expect(identity.sendHwid, true);
    expect(identity.deviceModel, 'Pixel');
  });

  test('identity: неизвестное поле → 400 (опечатка не должна молчать)',
      () async {
    final id = await createSub();
    await expectLater(
      patch(id, {
        'identity': {'send_hardware_id': true},
      }),
      throwsA(isA<BadRequest>()),
    );
    await expectLater(
      patch(id, {'identity': 'yes'}),
      throwsA(isA<BadRequest>()),
    );
  });

  // ──────────────────── on_update_action / тумблер (§323/§302) ────────────────

  test('on_update_action: валидное значение применяется, мусор → 400',
      () async {
    final id = await createSub();
    final r = await patch(id, {'on_update_action': 'reload'});
    expect(r['on_update_action'], 'reload');
    expect(listOf(id).onUpdateAction, SubscriptionOnUpdateAction.reload);

    // Толерантный fromJson здесь превратил бы опечатку в тихий `rebuild`.
    await expectLater(
      patch(id, {'on_update_action': 'relaod'}),
      throwsA(isA<BadRequest>()),
    );
    expect(listOf(id).onUpdateAction, SubscriptionOnUpdateAction.reload);
  });

  test('import_rules_enabled — плоское поле PATCH', () async {
    final id = await createSub();
    expect(listOf(id).importRulesEnabled, true);

    final r = await patch(id, {'import_rules_enabled': false});
    expect(r['import_rules_enabled'], false);
    expect(listOf(id).importRulesEnabled, false);
  });

  // ─────────────────────────── rules CRUD (§302) ───────────────────────────

  test('POST /rules → 201, порядок сохраняется, ?index вставляет в позицию',
      () async {
    final id = await createSub();

    final first = await subsHandler(
        req('POST', '/subs/$id/rules', body: disableRule('AAA')), ctx());
    expect((first as JsonResponse).status, 201);
    expect(asMap(first)['index'], 0);
    expect(asMap(first)['usable'], true);

    await subsHandler(
        req('POST', '/subs/$id/rules', body: disableRule('BBB')), ctx());
    // Вставка в начало — порядок значим (§332: последнее правило побеждает).
    await subsHandler(
      req('POST', '/subs/$id/rules',
          body: disableRule('CCC'), query: {'index': '0'}),
      ctx(),
    );

    final rules = (await rulesList(id))['rules'] as List;
    expect(rules.map((r) => (r as Map)['conditions'][0]['pattern']),
        ['CCC', 'AAA', 'BBB']);
    expect(rules.map((r) => (r as Map)['index']), [0, 1, 2]);
  });

  test('PATCH /rules/{idx} — частичное обновление, остальные поля целы',
      () async {
    final id = await createSub();
    await subsHandler(
        req('POST', '/subs/$id/rules', body: disableRule('AAA')), ctx());

    await subsHandler(
      req('PATCH', '/subs/$id/rules/0', body: {'enabled': false}),
      ctx(),
    );

    final rule = listOf(id).importRules.single;
    expect(rule.enabled, false);
    expect(rule.action, ImportRuleAction.disable);
    expect(rule.conditions.single.pattern, 'AAA');
    // enabled:false → правило не применяется (§302 isUsable).
    final listed = (await rulesList(id))['rules'] as List;
    expect((listed.single as Map)['usable'], false);
  });

  test('DELETE /rules/{idx} — удаляет одно, индексы пересчитываются', () async {
    final id = await createSub();
    for (final p in ['AAA', 'BBB', 'CCC']) {
      await subsHandler(
          req('POST', '/subs/$id/rules', body: disableRule(p)), ctx());
    }

    final r = asMap(
        await subsHandler(req('DELETE', '/subs/$id/rules/1'), ctx()));
    final rules = r['rules'] as List;
    expect(rules.map((x) => (x as Map)['conditions'][0]['pattern']),
        ['AAA', 'CCC']);
    // Индексы в снапшоте — свежие, по ним строится следующий вызов.
    expect(rules.map((x) => (x as Map)['index']), [0, 1]);
  });

  test('POST /rules/reorder — полная перестановка; частичная → 400', () async {
    final id = await createSub();
    for (final p in ['AAA', 'BBB', 'CCC']) {
      await subsHandler(
          req('POST', '/subs/$id/rules', body: disableRule(p)), ctx());
    }

    final r = asMap(await subsHandler(
      req('POST', '/subs/$id/rules/reorder', body: {
        'order': [2, 0, 1]
      }),
      ctx(),
    ));
    expect(
        (r['rules'] as List).map((x) => (x as Map)['conditions'][0]['pattern']),
        ['CCC', 'AAA', 'BBB']);

    for (final bad in [
      [0, 1],
      [0, 1, 1],
      [0, 1, 5],
    ]) {
      await expectLater(
        subsHandler(
          req('POST', '/subs/$id/rules/reorder', body: {'order': bad}),
          ctx(),
        ),
        throwsA(isA<BadRequest>()),
      );
    }
  });

  test('строгая валидация: неизвестное поле и битый enum → 400', () async {
    final id = await createSub();

    await expectLater(
      subsHandler(
        req('POST', '/subs/$id/rules', body: {'actoin': 'disable'}),
        ctx(),
      ),
      throwsA(isA<BadRequest>()),
    );
    await expectLater(
      subsHandler(
        req('POST', '/subs/$id/rules',
            body: {...disableRule('X'), 'action': 'replase'}),
        ctx(),
      ),
      throwsA(isA<BadRequest>()),
    );
    await expectLater(
      subsHandler(
        req('POST', '/subs/$id/rules', body: {
          'conditions': [
            {'path': 'tag', 'op': 'contians', 'pattern': 'X'},
          ],
        }),
        ctx(),
      ),
      throwsA(isA<BadRequest>()),
    );
    expect(listOf(id).importRules, isEmpty);
  });

  test('нежизнеспособное правило принимается с usable:false', () async {
    final id = await createSub();
    // Replace без target_path в режиме set — парсится, но на импорте скипнется.
    final r = await subsHandler(
      req('POST', '/subs/$id/rules', body: {
        'conditions': [
          {'path': 'tag', 'op': 'contains', 'pattern': 'X'},
        ],
        'action': 'replace',
      }),
      ctx(),
    );
    expect((r as JsonResponse).status, 201);
    expect(asMap(r)['usable'], false);
    expect(listOf(id).importRules, hasLength(1));
  });

  test('rules на не-подписке → 409, битый индекс → 404', () async {
    await controller.addFromInput(uriA); // UserServer
    final userId = controller.entries.single.id;
    await expectLater(
      subsHandler(req('GET', '/subs/$userId/rules'), ctx()),
      throwsA(isA<Conflict>()),
    );

    final id = await createSub();
    await expectLater(
      subsHandler(req('GET', '/subs/$id/rules/0'), ctx()),
      throwsA(isA<NotFound>()),
    );
    await expectLater(
      subsHandler(req('GET', '/subs/$id/rules/abc'), ctx()),
      throwsA(isA<NotFound>()),
    );
  });

  test('правила и identity переживают перезагрузку контроллера (persist)',
      () async {
    final id = await createSub();
    await subsHandler(
        req('POST', '/subs/$id/rules', body: disableRule('AAA')), ctx());
    await patch(id, {
      'identity': {'send_hwid': true, 'hwid': 'uuid-1'},
      'on_update_action': 'none',
      'import_rules_enabled': false,
    });

    final reloaded = SubscriptionController();
    await reloaded.init();
    final list = reloaded.entries.firstWhere((e) => e.id == id).list
        as SubscriptionServers;

    expect(list.importRules.single.conditions.single.pattern, 'AAA');
    expect(list.importRulesEnabled, false);
    expect(list.onUpdateAction, SubscriptionOnUpdateAction.none);
    expect(list.identity?.hwid, 'uuid-1');
    expect(list.identity?.sendHwid, true);
  });
}
