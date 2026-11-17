// §750 — setConnectionEnabled: решение и применение тем же путём, что UI.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/assistant/assistant_actions.dart';
import 'package:lxbox/services/assistant/assistant_index.dart';
import 'package:lxbox/services/settings_storage.dart';

import 'assistant_fixtures.dart';

void main() {
  group('planConnectionToggle (чистое решение)', () {
    final conns = assistantConnections([
      userServer('u1', wgNode('Office'), enabled: false),
      folder('f1', 'Off folder', [member(wgNode('Lab'))], enabled: false),
    ]);

    test('нет такого id → not_found', () {
      expect(
        () => planConnectionToggle(conns, id: 'Nope', enabled: true),
        throwsA(isA<AssistantError>()
            .having((e) => e.code, 'code', 'not_found')),
      );
    });

    test('уже в нужном состоянии → без изменений', () {
      expect(planConnectionToggle(conns, id: 'Office', enabled: false),
          isA<ConnectionAlready>());
      // Узел выключенной папки фактически выключен.
      expect(planConnectionToggle(conns, id: 'Lab', enabled: false),
          isA<ConnectionAlready>());
    });

    test('включение узла выключенной папки → source_off', () {
      expect(
        () => planConnectionToggle(conns, id: 'Lab', enabled: true),
        throwsA(isA<AssistantError>()
            .having((e) => e.code, 'code', 'source_off')),
      );
    });

    test('выключенный одиночный сервер включается', () {
      expect(planConnectionToggle(conns, id: 'Office', enabled: true),
          isA<ConnectionFlip>());
    });
  });

  group('setConnectionEnabled (хранилище + контроллер)', () {
    late SubscriptionController sub;
    late List<bool> applied;

    Future<Map<String, Object?>> fakeApply(
        {required bool startIfStopped}) async {
      applied.add(startIfStopped);
      return const {};
    }

    Future<Map<String, Object?>> run(String id, bool enabled) =>
        setConnectionEnabled(
          id: id,
          enabled: enabled,
          sub: sub,
          apply: fakeApply,
        );

    setUp(() async {
      await setUpTempStorage();
      applied = [];
      sub = SubscriptionController();
      addTearDown(sub.dispose);
      final lists = <ServerList>[
        userServer('u1', wgNode('Office'), enabled: false),
        folder('f1', 'Work', [member(wgNode('Lab')), member(tsNode('Tailnet'))]),
        subscription('s1', [wgNode('Edge')], tagPrefix: 'Prov'),
      ];
      await SettingsStorage.saveServerLists(lists);
      sub.debugSetEntries([for (final l in lists) SubscriptionEntry(list: l)]);
    });

    test('одиночный сервер: включение, пересборка со стартом, индекс',
        () async {
      final r = await run('Office', true);
      expect(r['status'], 'applied');
      expect(r['summary'], 'Turn on Office');
      expect(r['changed'], true);
      expect(sub.entries[0].list.enabled, isTrue);
      expect(applied, [true], reason: 'включение просит старт при down');
    });

    test('член папки: выключение без старта', () async {
      final r = await run('Lab', false);
      expect(r['summary'], 'Turn off Lab');
      final f = sub.entries[1].list as FolderServers;
      expect(f.members[0].enabled, isFalse);
      expect(f.members[1].enabled, isTrue, reason: 'соседи не тронуты');
      expect(applied, [false]);
    });

    test('узел подписки: отметка disabledHashes по идентичности', () async {
      await run('Prov Edge', false);
      final s = sub.entries[2].list as SubscriptionServers;
      expect(s.disabledHashes.keys, ['Edge']);
      await run('Prov Edge', true);
      expect((sub.entries[2].list as SubscriptionServers).disabledHashes,
          isEmpty);
      expect(applied, [false, true]);
    });

    test('уже в нужном состоянии → applied без пересборки', () async {
      final r = await run('Tailnet', true);
      expect(r['status'], 'applied');
      expect(r['changed'], false);
      expect(applied, isEmpty);
    });

    test('config_locked_for_debug → locked, хранилище не тронуто', () async {
      await SettingsStorage.setConfigLockedForDebug(true);
      await expectLater(
        run('Office', true),
        throwsA(isA<AssistantError>().having((e) => e.code, 'code', 'locked')),
      );
      expect(sub.entries[0].list.enabled, isFalse);
      expect(applied, isEmpty);
    });
  });
}
