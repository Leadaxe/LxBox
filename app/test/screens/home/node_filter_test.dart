import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/screens/home/node_filter.dart';

/// §048 — unit tests для `NodeFilter` predicate + `extractEmojis`.
/// Тестируется PURE predicate (без UI). Detour exclusion здесь не
/// проверяется — это pool filter в caller (locked decision #13).
void main() {
  NodeFilter makeFilter({
    RegExp? regex,
    bool regexInvert = false,
    Set<String> protocols = const {},
    bool protocolsInvert = false,
    Set<String> subscriptions = const {},
    bool subscriptionsInvert = false,
    int? maxPingMs,
    Map<String, String?> proto = const {},
    Map<String, Set<String>> sub = const {},
    Map<String, int?> ping = const {},
  }) {
    return NodeFilter(
      regex: regex,
      regexInvert: regexInvert,
      protocols: protocols,
      protocolsInvert: protocolsInvert,
      subscriptions: subscriptions,
      subscriptionsInvert: subscriptionsInvert,
      maxPingMs: maxPingMs,
      protocolOf: (t) => proto[t],
      subscriptionsOf: (t) => sub[t] ?? const <String>{},
      pingOf: (t) => ping[t],
    );
  }

  group('extractEmojis', () {
    test('RIS flag (🇷🇺 = single grapheme) → один entry', () {
      final result = NodeFilter.extractEmojis(['🇷🇺 Moscow', '🇷🇺 SPb']);
      expect(result, contains('🇷🇺'));
      expect(result.length, 1);
    });

    test('pictographic (⚡, 👑) — extracted', () {
      final result = NodeFilter.extractEmojis(['⚡ Fast', '👑 Premium']);
      expect(result, containsAll(['⚡', '👑']));
    });

    test('latin chars не false-positive', () {
      final result = NodeFilter.extractEmojis(['Moscow', 'NY-1']);
      expect(result, isEmpty);
    });

    test('frequency sort (most frequent first)', () {
      final result = NodeFilter.extractEmojis([
        '🇷🇺 N1', '🇷🇺 N2', '🇷🇺 N3', // 3x
        '🇺🇸 N1', '🇺🇸 N2', //              2x
        '🇩🇪 N1', //                          1x
      ]);
      expect(result, ['🇷🇺', '🇺🇸', '🇩🇪']);
    });
  });

  group('NodeFilter.passes — empty filter', () {
    test('всё пусто → true для любого tag', () {
      final f = makeFilter();
      expect(f.passes('🇷🇺 Moscow'), isTrue);
      expect(f.passes('whatever'), isTrue);
      expect(f.passes('⚙ detour-prefix'), isTrue,
          reason: 'detour-prefix не проверяется (это pool filter в caller)');
    });
  });

  group('NodeFilter.passes — regex', () {
    test('match — true (case-insensitive)', () {
      final f = makeFilter(regex: RegExp('moscow', caseSensitive: false));
      expect(f.passes('🇷🇺 Moscow'), isTrue);
      expect(f.passes('🇷🇺 MOSCOW #1'), isTrue);
    });

    test('non-match → false', () {
      final f = makeFilter(regex: RegExp('moscow'));
      expect(f.passes('🇺🇸 NY'), isFalse);
    });

    test('emoji в regex matchает (🇷🇺.*)', () {
      final f = makeFilter(regex: RegExp('🇷🇺'));
      expect(f.passes('🇷🇺 Moscow'), isTrue);
      expect(f.passes('🇺🇸 NY'), isFalse);
    });
  });

  group('NodeFilter.passes — regex invert (NOT)', () {
    test('invert ON + match → false (excluded)', () {
      final f = makeFilter(regex: RegExp('Moscow'), regexInvert: true);
      expect(f.passes('🇷🇺 Moscow'), isFalse);
    });

    test('invert ON + non-match → true (included)', () {
      final f = makeFilter(regex: RegExp('Moscow'), regexInvert: true);
      expect(f.passes('🇺🇸 NY'), isTrue);
    });

    test('invert OFF + match → true (как раньше)', () {
      final f = makeFilter(regex: RegExp('Moscow'));
      expect(f.passes('🇷🇺 Moscow'), isTrue);
    });

    test('invert ON без regex → no-op (true для всех)', () {
      final f = makeFilter(regexInvert: true);
      expect(f.passes('whatever'), isTrue);
    });
  });

  group('NodeFilter.passes — protocol', () {
    test('known proto в set → true', () {
      final f = makeFilter(
        protocols: {'vless'},
        proto: {'🇷🇺 M1': 'vless'},
      );
      expect(f.passes('🇷🇺 M1'), isTrue);
    });

    test('known proto не в set → false', () {
      final f = makeFilter(
        protocols: {'vless'},
        proto: {'🇺🇸 N1': 'vmess'},
      );
      expect(f.passes('🇺🇸 N1'), isFalse);
    });

    test('unknown proto (null) при active filter → false', () {
      final f = makeFilter(
        protocols: {'vless'},
        proto: {'🇩🇪 B1': null},
      );
      expect(f.passes('🇩🇪 B1'), isFalse,
          reason: 'locked decision #12 — unknown при active filter → non-matching');
    });

    test('unknown proto без active filter → true', () {
      final f = makeFilter(proto: {'🇩🇪 B1': null});
      expect(f.passes('🇩🇪 B1'), isTrue);
    });
  });

  group('NodeFilter.passes — protocol invert (NOT, §096)', () {
    test('invert ON + proto в set → false (excluded)', () {
      final f = makeFilter(
        protocols: {'vless'},
        protocolsInvert: true,
        proto: {'🇷🇺 M1': 'vless'},
      );
      expect(f.passes('🇷🇺 M1'), isFalse);
    });

    test('invert ON + proto не в set → true (included)', () {
      final f = makeFilter(
        protocols: {'vless'},
        protocolsInvert: true,
        proto: {'🇺🇸 N1': 'vmess'},
      );
      expect(f.passes('🇺🇸 N1'), isTrue);
    });

    test('invert ON + unknown proto (null) → true (не входит в set)', () {
      final f = makeFilter(
        protocols: {'vless'},
        protocolsInvert: true,
        proto: {'🇩🇪 B1': null},
      );
      expect(f.passes('🇩🇪 B1'), isTrue,
          reason: 'unknown ≠ vless → под invert проходит');
    });

    test('invert ON но protocols пуст → no-op (true)', () {
      final f = makeFilter(protocolsInvert: true, proto: {'X': 'vless'});
      expect(f.passes('X'), isTrue);
    });
  });

  group('NodeFilter.passes — subscription', () {
    test('known sub id в set → true', () {
      final f = makeFilter(
        subscriptions: {'sub-1'},
        sub: {'🇷🇺 M1': {'sub-1'}},
      );
      expect(f.passes('🇷🇺 M1'), isTrue);
    });

    test('UserServer (empty Set) попадает в `custom` category', () {
      final f = makeFilter(
        subscriptions: {'custom'},
        sub: {'CustomNode': const <String>{}},
      );
      expect(f.passes('CustomNode'), isTrue);
    });

    test('UserServer без `custom` в set → false', () {
      final f = makeFilter(
        subscriptions: {'sub-1'},
        sub: {'CustomNode': const <String>{}},
      );
      expect(f.passes('CustomNode'), isFalse);
    });

    test('§077 collision: нода с candidates {sub-a, sub-b} — chip sub-a → true', () {
      final f = makeFilter(
        subscriptions: {'sub-a'},
        sub: {'🇷🇺 M1': {'sub-a', 'sub-b'}},
      );
      expect(f.passes('🇷🇺 M1'), isTrue);
    });

    test('§077 collision: та же нода — chip sub-b → true (видна в обеих)', () {
      final f = makeFilter(
        subscriptions: {'sub-b'},
        sub: {'🇷🇺 M1': {'sub-a', 'sub-b'}},
      );
      expect(f.passes('🇷🇺 M1'), isTrue);
    });

    test('§077 collision: chip sub-c (не в candidates) → false', () {
      final f = makeFilter(
        subscriptions: {'sub-c'},
        sub: {'🇷🇺 M1': {'sub-a', 'sub-b'}},
      );
      expect(f.passes('🇷🇺 M1'), isFalse);
    });

    test('§077 multi-chip {sub-a, sub-c} ∩ candidates {sub-a, sub-b} → true (any-match)', () {
      // Audit finding #4 — symmetric intersection: с multi-chip side.
      final f = makeFilter(
        subscriptions: {'sub-a', 'sub-c'},
        sub: {'🇷🇺 M1': {'sub-a', 'sub-b'}},
      );
      expect(f.passes('🇷🇺 M1'), isTrue);
    });

    test('§077 multi-chip {sub-c, sub-d} disjoint от candidates {sub-a, sub-b} → false', () {
      final f = makeFilter(
        subscriptions: {'sub-c', 'sub-d'},
        sub: {'🇷🇺 M1': {'sub-a', 'sub-b'}},
      );
      expect(f.passes('🇷🇺 M1'), isFalse);
    });

    test('custom chip + node с known sub → false (UserServer-only filter)', () {
      // Audit finding #5: custom branch + non-empty candidates inversion check.
      final f = makeFilter(
        subscriptions: {'custom'},
        sub: {'🇷🇺 M1': {'sub-1'}},
      );
      expect(f.passes('🇷🇺 M1'), isFalse);
    });

    test('mixed {custom, sub-1} chips + UserServer → true', () {
      final f = makeFilter(
        subscriptions: {'custom', 'sub-1'},
        sub: {'CustomNode': const <String>{}},
      );
      expect(f.passes('CustomNode'), isTrue);
    });

    test('mixed {custom, sub-1} chips + known sub-1 node → true', () {
      final f = makeFilter(
        subscriptions: {'custom', 'sub-1'},
        sub: {'🇷🇺 M1': {'sub-1'}},
      );
      expect(f.passes('🇷🇺 M1'), isTrue);
    });

    test('subscription filter off (empty Set) + non-empty candidates → true', () {
      // Audit finding #16: контракт «filter off ignores whatever lookup returns».
      final f = makeFilter(
        sub: {'🇷🇺 M1': {'sub-a', 'sub-b'}},
      );
      expect(f.passes('🇷🇺 M1'), isTrue);
    });

    test('subscription filter off (empty Set) + empty candidates → true', () {
      final f = makeFilter(sub: {'CustomNode': const <String>{}});
      expect(f.passes('CustomNode'), isTrue);
    });
  });

  group('NodeFilter.passes — subscription invert (NOT, §096)', () {
    test('invert ON + нода из выбранной подписки → false', () {
      final f = makeFilter(
        subscriptions: {'sub-1'},
        subscriptionsInvert: true,
        sub: {'🇷🇺 M1': {'sub-1'}},
      );
      expect(f.passes('🇷🇺 M1'), isFalse);
    });

    test('invert ON + нода НЕ из выбранной → true', () {
      final f = makeFilter(
        subscriptions: {'sub-1'},
        subscriptionsInvert: true,
        sub: {'🇺🇸 N1': {'sub-2'}},
      );
      expect(f.passes('🇺🇸 N1'), isTrue);
    });

    test('invert ON + custom-нода (empty candidates) при chip sub-1 → true', () {
      final f = makeFilter(
        subscriptions: {'sub-1'},
        subscriptionsInvert: true,
        sub: {'CustomNode': const <String>{}},
      );
      expect(f.passes('CustomNode'), isTrue,
          reason: 'custom ≠ sub-1 → под invert проходит');
    });

    test('invert ON + custom chip + custom-нода → false (исключена)', () {
      final f = makeFilter(
        subscriptions: {'custom'},
        subscriptionsInvert: true,
        sub: {'CustomNode': const <String>{}},
      );
      expect(f.passes('CustomNode'), isFalse);
    });

    test('invert ON но subscriptions пуст → no-op (true)', () {
      final f = makeFilter(
        subscriptionsInvert: true,
        sub: {'🇷🇺 M1': {'sub-1'}},
      );
      expect(f.passes('🇷🇺 M1'), isTrue);
    });
  });

  group('NodeFilter.passes — ping', () {
    test('delay ≤ N → true', () {
      final f = makeFilter(maxPingMs: 100, ping: {'M1': 50});
      expect(f.passes('M1'), isTrue);
    });

    test('delay > N → false', () {
      final f = makeFilter(maxPingMs: 100, ping: {'N1': 150});
      expect(f.passes('N1'), isFalse);
    });

    test('delay == null (untested) → true (locked decision #11)', () {
      final f = makeFilter(maxPingMs: 100, ping: {'U1': null});
      expect(f.passes('U1'), isTrue);
    });

    test('ping filter off (maxPingMs=null) → true для любого delay', () {
      final f = makeFilter(ping: {'N1': 99999});
      expect(f.passes('N1'), isTrue);
    });

    test('delay == maxPingMs (boundary) → true', () {
      final f = makeFilter(maxPingMs: 100, ping: {'M1': 100});
      expect(f.passes('M1'), isTrue);
    });
  });

  group('NodeFilter.passes — AND combine', () {
    test('regex match + protocol fail → false', () {
      final f = makeFilter(
        regex: RegExp('Moscow'),
        protocols: {'vless'},
        proto: {'🇷🇺 Moscow': 'vmess'},
      );
      expect(f.passes('🇷🇺 Moscow'), isFalse);
    });

    test('всё passes → true', () {
      final f = makeFilter(
        regex: RegExp('Moscow'),
        protocols: {'vless'},
        subscriptions: {'sub-1'},
        maxPingMs: 100,
        proto: {'🇷🇺 Moscow': 'vless'},
        sub: {'🇷🇺 Moscow': {'sub-1'}},
        ping: {'🇷🇺 Moscow': 42},
      );
      expect(f.passes('🇷🇺 Moscow'), isTrue);
    });
  });

  group('NodeFilter.passes — detour не в predicate', () {
    test('tag с detour-prefix НЕ rejects (это caller responsibility)', () {
      final f = makeFilter();
      expect(f.passes('⚙ detour-node'), isTrue,
          reason:
              'locked decision #13 — detour exclusion это pool filter в caller, не часть NodeFilter');
    });
  });
}
