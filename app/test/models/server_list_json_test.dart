import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/import_rule.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/subscription_meta.dart';

void main() {
  group('ServerList JSON round-trip', () {
    test('SubscriptionServers → JSON → SubscriptionServers', () {
      final original = SubscriptionServers(
        id: 'sub-1',
        name: 'My Sub',
        enabled: true,
        tagPrefix: '🌐',
        detourPolicy: const DetourPolicy(
            overrideDetour: 'jump-1', replaceDetourChain: true),
        url: 'https://example.com/sub?token=test',
        meta: const SubscriptionMeta(
          uploadBytes: 100,
          downloadBytes: 2000,
          totalBytes: 107374182400,
          profileTitle: 'Test Profile',
        ),
        lastUpdated: DateTime.utc(2026, 4, 18, 10, 0),
        updateIntervalHours: 12,
        lastNodeCount: 42,
      );

      final roundtripped =
          ServerList.fromJson(original.toJson()) as SubscriptionServers;

      expect(roundtripped.id, original.id);
      expect(roundtripped.name, original.name);
      expect(roundtripped.tagPrefix, original.tagPrefix);
      expect(roundtripped.detourPolicy, original.detourPolicy);
      expect(roundtripped.url, original.url);
      expect(roundtripped.meta, original.meta);
      expect(roundtripped.lastUpdated, original.lastUpdated);
      expect(roundtripped.updateIntervalHours, 12);
      expect(roundtripped.lastNodeCount, 42);
      // §289 — identity не задан → null после roundtrip.
      expect(roundtripped.identity, isNull);
    });

    test('§289 — identity переживает JSON round-trip (§283-инвариант)', () {
      final original = SubscriptionServers(
        id: 'sub-id',
        name: 'S',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://e.com/sub',
        identity: const SubscriptionIdentityOverride(
          userAgent: 'Panel/1',
          sendHwid: true,
          hwid: 'HW-42',
          deviceOs: 'harmonyos',
          verOs: '4.2',
          deviceModel: 'P60',
        ),
      );
      final r = ServerList.fromJson(original.toJson()) as SubscriptionServers;
      expect(r.identity, isNotNull);
      expect(r.identity!.userAgent, 'Panel/1');
      expect(r.identity!.sendHwid, isTrue);
      expect(r.identity!.hwid, 'HW-42');
      expect(r.identity!.deviceModel, 'P60');
    });

    test('§289 — copyWith(clearIdentity) снимает слепок в null', () {
      final withId = SubscriptionServers(
        id: 'x',
        name: 'X',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://e.com/sub',
        identity: const SubscriptionIdentityOverride(hwid: 'HW'),
      );
      // Обычный copyWith без identity сохраняет слепок.
      expect(withId.copyWith(name: 'Y').identity, isNotNull);
      // clearIdentity снимает.
      expect(withId.copyWith(clearIdentity: true).identity, isNull);
    });

    test('§302 — importRules переживают JSON round-trip (§221-инвариант)', () {
      final original = SubscriptionServers(
        id: 'x',
        name: 'X',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://e.com/sub',
        importRules: const [
          ImportRule(
            conditions: [
              ImportRuleCondition(
                path: 'tls.utls.fingerprint',
                op: ImportRuleOperator.contains,
                pattern: 'hellochrome_120',
              ),
            ],
            action: ImportRuleAction.replace,
            targetPath: 'tls.utls.fingerprint',
            replacement: 'chrome',
          ),
          ImportRule(
            conditions: [
              ImportRuleCondition(
                path: 'tag',
                op: ImportRuleOperator.matches,
                pattern: r'.*Netherlands.*',
                caseSensitive: true,
              ),
            ],
            action: ImportRuleAction.disable,
          ),
        ],
        importRulesEnabled: false,
      );

      final r = ServerList.fromJson(original.toJson()) as SubscriptionServers;
      expect(r.importRules, hasLength(2));
      expect(r.importRules[0].action, ImportRuleAction.replace);
      expect(r.importRules[0].conditions.single.path, 'tls.utls.fingerprint');
      expect(r.importRules[0].targetPath, 'tls.utls.fingerprint');
      expect(r.importRules[0].replacement, 'chrome');
      expect(r.importRules[1].action, ImportRuleAction.disable);
      expect(r.importRules[1].conditions.single.op, ImportRuleOperator.matches);
      expect(r.importRules[1].conditions.single.caseSensitive, isTrue);
      // Порядок сохраняется (значим для цепочки replace→disable).
      expect(r.importRules[1].conditions.single.pattern, r'.*Netherlands.*');
      expect(r.importRulesEnabled, isFalse);
    });

    test('§302 — пустые importRules: ключи не пишутся, дефолты после rt', () {
      final original = SubscriptionServers(
        id: 'x',
        name: 'X',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://e.com/sub',
      );
      final j = original.toJson();
      // Пустой список и дефолтный тумблер не раздувают JSON.
      expect(j.containsKey('import_rules'), isFalse);
      expect(j.containsKey('import_rules_enabled'), isFalse);
      final r = ServerList.fromJson(j) as SubscriptionServers;
      expect(r.importRules, isEmpty);
      expect(r.importRulesEnabled, isTrue);
      // copyWith сохраняет правила при мутации других полей.
      final withRules = original.copyWith(importRules: const [
        ImportRule(
          conditions: [ImportRuleCondition(path: 'tag', pattern: 'a')],
          action: ImportRuleAction.disable,
        )
      ]);
      expect(withRules.copyWith(name: 'Y').importRules, hasLength(1));
    });

    test('UserServer → JSON → UserServer', () {
      final original = UserServer(
        id: 'user-1',
        name: 'Pasted',
        enabled: true,
        tagPrefix: '🔗',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.utc(2026, 4, 18),
        rawBody: 'vless://...',
      );

      final j = original.toJson();
      expect(j['type'], 'user');

      final rt = ServerList.fromJson(j) as UserServer;
      expect(rt.origin, UserSource.paste);
      expect(rt.createdAt, original.createdAt);
      expect(rt.rawBody, original.rawBody);
    });

    test('DetourPolicy defaults round-trip', () {
      final j = DetourPolicy.defaults.toJson();
      expect(DetourPolicy.fromJson(j), DetourPolicy.defaults);
    });

    test('fromJson throws on unknown type', () {
      expect(
        () => ServerList.fromJson({'type': 'invalid', 'id': 'x'}),
        throwsFormatException,
      );
    });

    test('copyWith preserves id', () {
      final s = SubscriptionServers(
        id: 'keep',
        name: 'A',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://x',
      );
      final updated = s.copyWith(name: 'B', lastNodeCount: 5);
      expect(updated.id, 'keep');
      expect(updated.name, 'B');
      expect(updated.lastNodeCount, 5);
      expect(updated.url, 'https://x');
    });
  });

  // §283 — per-node disable: отметки живут в записи подписки и обязаны
  // переживать toJson→fromJson (merge-импорт backup гоняет ровно этот
  // round-trip) и copyWith-мутации других полей.
  group('§283 disabledHashes', () {
    SubscriptionServers sub({Map<String, DateTime> disabled = const {}}) =>
        SubscriptionServers(
          id: 's1',
          name: 'S',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          url: 'https://x',
          disabledHashes: disabled,
        );

    test('toJson → fromJson сохраняет hash → lastSeen', () {
      final t1 = DateTime.utc(2026, 7, 18, 10);
      final t2 = DateTime.utc(2026, 7, 1, 8, 30);
      final rt = ServerList.fromJson(
              sub(disabled: {'aaa': t1, 'bbb': t2}).toJson())
          as SubscriptionServers;
      expect(rt.disabledHashes, {'aaa': t1, 'bbb': t2});
    });

    test('пустые отметки → ключа в JSON нет; старый JSON без ключа → {}', () {
      final j = sub().toJson();
      expect(j.containsKey('disabled_hashes'), isFalse);
      final rt = ServerList.fromJson(j) as SubscriptionServers;
      expect(rt.disabledHashes, isEmpty);
    });

    test('copyWith других полей отметки НЕ затирает', () {
      final t = DateTime.utc(2026, 7, 18);
      final updated = sub(disabled: {'aaa': t})
          .copyWith(name: 'renamed', lastNodeCount: 9);
      expect(updated.disabledHashes, {'aaa': t});
    });

    test('толерантный парс: мусор вместо map / битые даты → скип', () {
      final base = sub().toJson();
      expect(
          (ServerList.fromJson({...base, 'disabled_hashes': 'oops'})
                  as SubscriptionServers)
              .disabledHashes,
          isEmpty);
      final mixed = ServerList.fromJson({
        ...base,
        'disabled_hashes': {'good': '2026-07-18T00:00:00.000Z', 'bad': 42},
      }) as SubscriptionServers;
      expect(mixed.disabledHashes.keys, ['good']);
    });
  });
}
