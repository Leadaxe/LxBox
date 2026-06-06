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
    Set<String> subscriptions = const {},
    int? maxPingMs,
    Map<String, String?> proto = const {},
    Map<String, String?> sub = const {},
    Map<String, int?> ping = const {},
  }) {
    return NodeFilter(
      regex: regex,
      regexInvert: regexInvert,
      protocols: protocols,
      subscriptions: subscriptions,
      maxPingMs: maxPingMs,
      protocolOf: (t) => proto[t],
      subscriptionOf: (t) => sub[t],
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

  group('NodeFilter.passes — subscription', () {
    test('known sub id в set → true', () {
      final f = makeFilter(
        subscriptions: {'sub-1'},
        sub: {'🇷🇺 M1': 'sub-1'},
      );
      expect(f.passes('🇷🇺 M1'), isTrue);
    });

    test('UserServer (null sub) попадает в `custom` category', () {
      final f = makeFilter(
        subscriptions: {'custom'},
        sub: {'CustomNode': null},
      );
      expect(f.passes('CustomNode'), isTrue);
    });

    test('UserServer без `custom` в set → false', () {
      final f = makeFilter(
        subscriptions: {'sub-1'},
        sub: {'CustomNode': null},
      );
      expect(f.passes('CustomNode'), isFalse);
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
        sub: {'🇷🇺 Moscow': 'sub-1'},
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
