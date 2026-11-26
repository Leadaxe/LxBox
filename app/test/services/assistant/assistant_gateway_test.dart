// §750 — шлюз ассистента к Debug API: политика, исполнение, справка.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/services/assistant/assistant_gateway.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/settings_storage.dart';

import 'assistant_fixtures.dart';

void main() {
  group('assistantPolicy', () {
    const allow = AssistantAccess.allow;
    const changes = AssistantAccess.changes;
    const deny = AssistantAccess.deny;

    AssistantAccess p(String method, String path,
            [Map<String, String> query = const {}]) =>
        assistantPolicy(method, path, query);

    final cases = <(String, String, AssistantAccess)>[
      // Чтения.
      ('GET', '/state', allow),
      ('GET', '/state/rules', allow),
      ('GET', '/state/vpn', allow),
      ('GET', '/state/subs', allow),
      ('GET', '/rules', allow),
      ('GET', '/rules/abc', allow),
      ('GET', '/directions/vpn-1', allow),
      ('GET', '/subs/s1', allow),
      ('GET', '/subs/s1/rules/0', allow),
      ('GET', '/folders/f1', allow),
      ('GET', '/pool', allow),
      ('GET', '/assistant/overview', allow),
      ('GET', '/settings/node_sort', allow),
      ('GET', '/settings/ping_options', allow),
      // Диагностика.
      ('POST', '/assistant/check-url', allow),
      ('POST', '/assistant/check-exit', allow),
      ('POST', '/action/check-config', allow),
      ('POST', '/action/urltest-all', allow),
      ('GET', '/chains/c1/probe', allow),
      ('POST', '/folders/f1/probe', allow),
      // VPN и выбор.
      ('POST', '/action/start-vpn-headless', allow),
      ('POST', '/action/reload-vpn', allow),
      ('POST', '/action/switch-node', allow),
      ('POST', '/assistant/exit', allow),
      // Изменения.
      ('POST', '/rules', changes),
      ('POST', '/rules/reorder', changes),
      ('PATCH', '/rules/abc', changes),
      ('DELETE', '/directions/vpn-2', changes),
      ('PATCH', '/subs/s1', changes),
      ('POST', '/subs/s1/refresh', changes),
      ('POST', '/action/refresh-subs', changes),
      ('POST', '/settings/rebuild-config', changes),
      ('PUT', '/settings/route_final', changes),
      ('PUT', '/settings/tun_apps', changes),
      ('POST', '/assistant/connection', changes),
      // Закрыто.
      ('GET', '/config', deny),
      ('GET', '/state/storage', deny),
      ('GET', '/backup/export', deny),
      ('GET', '/logs/app', deny),
      ('GET', '/nodes/link', deny),
      ('GET', '/mixins', deny),
      // §762 — тестовый outbound impair ассистенту не виден.
      ('GET', '/impair/node-a', deny),
      ('POST', '/impair/node-a/set', deny),
      ('POST', '/impair/node-a/schedule', deny),
      ('PATCH', '/nodes/node-a', deny),
      ('PUT', '/settings/vars/appfunctions_allow_changes', deny),
      ('PUT', '/settings/dns_options/servers', deny),
      ('PUT', '/settings/config_locked', deny),
      ('GET', '/settings/vpn_mode', deny),
      ('PUT', '/settings/vpn_mode', deny),
      ('GET', '/settings/vpn/allow_bypass', deny),
      ('POST', '/subs', deny),
      ('DELETE', '/subs/s1', deny),
      ('POST', '/subs/s1/rules', deny),
      ('POST', '/folders', deny),
      ('DELETE', '/folders/f1', deny),
      ('POST', '/chains', deny),
      ('GET', '/chains', deny),
      ('GET', '/chains/c1', deny),
      ('POST', '/action/start-vpn', deny),
      ('POST', '/action/force-stop-vpn', deny),
      ('POST', '/action/toast', deny),
      ('GET', '/unknown', deny),
      ('GET', '/', deny),
      ('GET', '/rules/../config', deny),
      ('OPTIONS', '/rules', deny),
    ];
    for (final (method, path, expected) in cases) {
      test('$method $path → ${expected.name}', () {
        expect(p(method, path), expected);
      });
    }

    test('reveal и warnings закрывают маршрут', () {
      expect(p('GET', '/state/subs', const {'reveal': 'true'}), deny);
      expect(p('GET', '/subs', const {'reveal': 'false'}), deny);
      expect(p('GET', '/folders/f1', const {'reveal': '1'}), deny);
      expect(p('GET', '/subs/s1', const {'warnings': 'true'}), deny);
      expect(p('POST', '/rules', const {'rebuild': 'true'}), changes);
    });

    test('метод без учёта регистра', () {
      expect(p('get', '/state'), allow);
      expect(p('Post', '/rules'), changes);
      expect(p(' delete ', '/rules/x'), changes);
    });
  });

  group('assistantGatewayCall', () {
    setUp(() async {
      await setUpTempStorage();
      await SettingsStorage.setDirections(
          [const Direction(tag: 'vpn-1', label: 'Proxy')]);
    });

    tearDown(() {
      DebugRegistry.I.home = null;
      DebugRegistry.I.sub = null;
    });

    void bindControllers() {
      final home = HomeController();
      final sub = SubscriptionController();
      addTearDown(home.dispose);
      addTearDown(sub.dispose);
      DebugRegistry.I.home = home;
      DebugRegistry.I.sub = sub;
    }

    test('пустой реестр → 503 not_ready', () async {
      final r = await assistantGatewayCall('GET', '/directions', null);
      expect(r.status, 503);
      expect(jsonDecode(r.body), {'error': 'not_ready'});
    });

    test('чтение проходит', () async {
      bindControllers();
      final r = await assistantGatewayCall('GET', '/directions', null);
      expect(r.status, 200);
      final list = jsonDecode(r.body) as List;
      expect((list.single as Map)['tag'], 'vpn-1');
    });

    test('закрытый маршрут и reveal → 403', () async {
      bindControllers();
      for (final path in ['/config', '/state/subs?reveal=true', '/backup/export']) {
        final r = await assistantGatewayCall('GET', path, null);
        expect(r.status, 403, reason: path);
        expect(jsonDecode(r.body)['error'], startsWith('forbidden'));
      }
    });

    test('изменение при выключенном тумблере → 403, правило не создано',
        () async {
      bindControllers();
      final r = await assistantGatewayCall(
          'POST', '/rules', jsonEncode({'name': 'Chat', 'kind': 'inline'}));
      expect(r.status, 403);
      expect(jsonDecode(r.body)['error'],
          contains('Let assistants change settings'));
      expect(await SettingsStorage.getCustomRules(), isEmpty);
    });

    test('изменение при включённом тумблере — POST /rules создаёт правило',
        () async {
      bindControllers();
      await SettingsStorage.setAppFunctionsAllowChanges(true);
      final r = await assistantGatewayCall(
          'post', '/rules', jsonEncode({'name': 'Chat', 'kind': 'inline'}));
      expect(r.status, 201);
      expect(jsonDecode(r.body)['name'], 'Chat');
      final rules = await SettingsStorage.getCustomRules();
      expect(rules.single.name, 'Chat');
    });

    test('PATCH /subs/{id}: кроме enabled/name — 403', () async {
      bindControllers();
      await SettingsStorage.setAppFunctionsAllowChanges(true);
      final r = await assistantGatewayCall(
          'PATCH', '/subs/s1', jsonEncode({'url': 'https://evil.example/'}));
      expect(r.status, 403);
      expect(jsonDecode(r.body)['error'], contains('url'));
    });

    test('ошибка обработчика — конверт Debug API со статусом', () async {
      bindControllers();
      final r = await assistantGatewayCall('GET', '/rules/missing', null);
      expect(r.status, 404);
      expect((jsonDecode(r.body) as Map)['error'], isA<Map>());
    });

    test('ответ больше предела → 413', () async {
      bindControllers();
      final r = await assistantGatewayCall('GET', '/directions', null,
          maxResponseBytes: 8);
      expect(r.status, 413);
      expect(jsonDecode(r.body)['error'],
          'response too large: narrow the request');
    });

    test('справка: только разрешённые маршруты, изменения помечены', () async {
      final r = await assistantGatewayCall('GET', '/assistant/help', null);
      expect(r.status, 200);
      final endpoints = ((jsonDecode(r.body) as Map)['endpoints'] as List)
          .cast<Map<String, dynamic>>();
      expect(endpoints, isNotEmpty);
      for (final e in endpoints) {
        final probe =
            (e['path'] as String).replaceAll(RegExp(r'\{[^}]*\}'), 'x');
        final access = assistantPolicy(e['method'] as String, probe, const {});
        expect(access, isNot(AssistantAccess.deny),
            reason: '${e['method']} ${e['path']}');
        expect(e['requires'],
            access == AssistantAccess.changes ? 'change_permission' : isNull,
            reason: '${e['method']} ${e['path']}');
      }
      final keys = {for (final e in endpoints) '${e['method']} ${e['path']}'};
      expect(keys, containsAll(['GET /state', 'POST /rules', 'GET /rules']));
      expect(keys, isNot(contains('GET /config')));
      expect(keys, isNot(contains('GET /backup/export')));
      expect(keys, isNot(contains('PUT /settings/vars/{key}')));
      expect(keys, isNot(contains('GET /settings/vpn_mode')));
      // `GET|PUT` разложен по методам: чтение — без пометки.
      final nodeSortGet = endpoints.singleWhere(
          (e) => e['method'] == 'GET' && e['path'] == '/settings/node_sort');
      expect(nodeSortGet['requires'], isNull);
      final nodeSortPut = endpoints.singleWhere(
          (e) => e['method'] == 'PUT' && e['path'] == '/settings/node_sort');
      expect(nodeSortPut['requires'], 'change_permission');
    });
  });

  test('scrubAssistantErrors скрывает адреса только в текстах ошибок', () {
    final out = scrubAssistantErrors({
      'last_start_error': 'dial tcp 203.0.113.7:443: i/o timeout',
      'layers': [
        {'tag': 'DE 1', 'error': 'connect example.org:443 refused'},
      ],
      'tag': 'host.example.com',
    }) as Map;
    expect(out['last_start_error'], 'dial tcp ***:443: i/o timeout');
    expect(((out['layers'] as List).single as Map)['error'],
        'connect ***:443 refused');
    expect(out['tag'], 'host.example.com');
  });
}
