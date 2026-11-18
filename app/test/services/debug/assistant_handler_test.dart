// §750 — `/assistant/*`: проброс ответов натива и отображение его ошибок
// в HTTP; канал мокается.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/assistant.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/vpn/platform_channels.dart';

import '../assistant/assistant_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel(PlatformChannels.methods);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Object? Function(MethodCall call) answer;

  DebugContext ctx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 11, 17),
      );

  DebugRequest req(String method, String path,
          {Map<String, dynamic>? body, Map<String, String> query = const {}}) =>
      DebugRequest.forTest(
        method: method,
        path: path,
        query: query,
        body: body == null ? const [] : utf8.encode(jsonEncode(body)),
      );

  setUp(() async {
    // §750 — overview/app-route собирают индекс из хранилища в момент запроса.
    await setUpTempStorage();
    calls = [];
    answer = (_) => null;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return answer(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
  });

  test('GET /assistant/overview — ответ натива как есть', () async {
    answer = (_) => {
          'vpn_status': 'connected',
          'default_route': 'vpn-1',
          'directions': [
            {'tag': 'vpn-1', 'name': 'Proxy', 'exit_count': 2, 'current_exit': 'A'},
          ],
          'connections': <Object?>[],
        };
    final r = await assistantHandler(req('GET', '/assistant/overview'), ctx())
        as JsonResponse;
    expect(calls.single.method, 'assistantOverview');
    final body = r.body as Map<String, dynamic>;
    expect(body['vpn_status'], 'connected');
    expect((body['directions'] as List).single['name'], 'Proxy');
  });

  test('чтения передают аргументы нативу', () async {
    answer = (call) => switch (call.method) {
          'assistantFindApps' => [
              {'package': 'org.example.chat', 'label': 'Chat'},
            ],
          _ => {'ok': true},
        };
    await assistantHandler(
        req('GET', '/assistant/exits',
            query: {'direction': 'vpn-1', 'q': 'frank'}),
        ctx());
    await assistantHandler(
        req('POST', '/assistant/check-url',
            body: {'url': 'https://example.com', 'app': 'org.example.chat'}),
        ctx());
    await assistantHandler(
        req('POST', '/assistant/check-exit', body: {'direction': 'vpn-2'}),
        ctx());
    final apps = await assistantHandler(
        req('GET', '/assistant/apps', query: {'q': 'chat'}), ctx());
    await assistantHandler(
        req('GET', '/assistant/app-route', query: {'app': 'org.example.chat'}),
        ctx());
    await assistantHandler(
        req('POST', '/assistant/exit',
            body: {'direction': 'vpn-1', 'exit': 'DE Frankfurt'}),
        ctx());

    expect((apps as JsonResponse).body, [
      {'package': 'org.example.chat', 'label': 'Chat'},
    ]);
    expect([for (final c in calls) c.method], [
      'assistantListExits',
      'assistantCheckUrl',
      'assistantCheckExit',
      'assistantFindApps',
      'assistantAppRoute',
      'assistantSelectExit',
    ]);
    expect(calls[0].arguments, {'direction': 'vpn-1', 'query': 'frank'});
    expect(calls[1].arguments,
        {'url': 'https://example.com', 'app': 'org.example.chat'});
    expect(calls[2].arguments, {'direction': 'vpn-2'});
    expect(calls[3].arguments, {'query': 'chat'});
    expect(calls[4].arguments['app'], 'org.example.chat');
    // Индекс собран в момент запроса и передан аргументом.
    expect(jsonDecode(calls[4].arguments['index'] as String),
        containsPair('v', 1));
    expect(calls[5].arguments, {'direction': 'vpn-1', 'exit': 'DE Frankfurt'});
  });

  group('ошибки натива → HTTP', () {
    Future<DebugError> errorFor(String code) async {
      answer = (_) => {
            'error': {'code': code, 'message': 'msg'},
          };
      try {
        await assistantHandler(req('GET', '/assistant/overview'), ctx());
      } on DebugError catch (e) {
        return e;
      }
      fail('ожидалась ошибка для $code');
    }

    for (final (code, status) in [
      ('not_found', 404),
      ('invalid_argument', 400),
      ('vpn_off', 409),
      ('busy', 409),
      ('locked', 409),
      ('core_error', 500),
      ('something_new', 500),
    ]) {
      test('$code → $status', () async {
        final e = await errorFor(code);
        expect(e.status, status);
        expect(e.message, '$code: msg');
      });
    }

    test('старый натив без метода → 500', () async {
      messenger.setMockMethodCallHandler(methods, null);
      await expectLater(
        assistantHandler(req('GET', '/assistant/overview'), ctx()),
        throwsA(isA<InternalError>()),
      );
    });
  });

  test('валидация входа: нет обязательного поля → 400', () async {
    for (final r in [
      req('GET', '/assistant/exits'),
      req('POST', '/assistant/check-url', body: {}),
      req('POST', '/assistant/check-exit', body: {'direction': ' '}),
      req('GET', '/assistant/apps'),
      req('GET', '/assistant/app-route'),
      req('POST', '/assistant/exit', body: {'direction': 'vpn-1'}),
      req('POST', '/assistant/connection', body: {'id': 'Office'}),
      req('POST', '/assistant/overview'),
    ]) {
      await expectLater(assistantHandler(r, ctx()), throwsA(isA<BadRequest>()),
          reason: '${r.method} ${r.path}');
    }
    expect(calls, isEmpty);
  });

  test('неизвестный путь → 404', () async {
    await expectLater(
      assistantHandler(req('POST', '/assistant/app-route-x'), ctx()),
      throwsA(isA<NotFound>()),
    );
  });

  group('POST /assistant/connection', () {
    late SubscriptionController sub;

    setUp(() async {
      await setUpTempStorage();
      sub = SubscriptionController();
      addTearDown(sub.dispose);
      final lists = [userServer('u1', wgNode('Office'))];
      await SettingsStorage.saveServerLists(lists);
      sub.debugSetEntries([for (final l in lists) SubscriptionEntry(list: l)]);
      DebugRegistry.I.sub = sub;
      addTearDown(() => DebugRegistry.I.sub = null);
    });

    test('уже включено → applied без пересборки', () async {
      final r = await assistantHandler(
          req('POST', '/assistant/connection',
              body: {'id': 'Office', 'enabled': true}),
          ctx()) as JsonResponse;
      expect(r.body, {
        'status': 'applied',
        'summary': 'Turn on Office',
        'changed': false,
      });
    });

    test('нет такого подключения → 404', () async {
      await expectLater(
        assistantHandler(
            req('POST', '/assistant/connection',
                body: {'id': 'Nope', 'enabled': true}),
            ctx()),
        throwsA(isA<NotFound>()),
      );
    });

    test('config_locked_for_debug → 409', () async {
      await SettingsStorage.setConfigLockedForDebug(true);
      await expectLater(
        assistantHandler(
            req('POST', '/assistant/connection',
                body: {'id': 'Office', 'enabled': false}),
            ctx()),
        throwsA(isA<Conflict>()),
      );
      expect(sub.entries.single.list.enabled, isTrue);
    });
  });
}
