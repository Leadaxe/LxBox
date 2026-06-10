import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/tag_resolver.dart';

/// §085 R1 — unit tests for TagResolver (единый владелец display-tag logic).
/// Поглощает бывшие consts_test (isDetourDisplayTag → isDetourMarker).
void main() {
  group('displayTag (forward)', () {
    test('empty prefix → bare', () {
      expect(TagResolver.displayTag('', 'M1'), 'M1');
    });
    test('non-empty prefix → "prefix bare"', () {
      expect(TagResolver.displayTag('🇷🇺 RU', 'M1'), '🇷🇺 RU M1');
    });
  });

  group('isDetourMarker', () {
    test('bare-form "⚙ NodeA" → true', () {
      expect(TagResolver.isDetourMarker('⚙ NodeA'), isTrue);
    });
    test('prefixed "🇷🇺 RU ⚙ HopB" → true (маркер в середине)', () {
      expect(TagResolver.isDetourMarker('🇷🇺 RU ⚙ HopB'), isTrue);
    });
    test('ASCII prefix "SUB ⚙ NodeA" → true', () {
      expect(TagResolver.isDetourMarker('SUB ⚙ NodeA'), isTrue);
    });
    test('collision-suffix "🇷🇺 RU ⚙ HopB-1" → true', () {
      expect(TagResolver.isDetourMarker('🇷🇺 RU ⚙ HopB-1'), isTrue);
    });
    test('multi-word prefix "My Prefix ⚙ Hop" → true', () {
      expect(TagResolver.isDetourMarker('My Prefix ⚙ Hop'), isTrue);
    });
    test('plain node → false', () {
      expect(TagResolver.isDetourMarker('NodeA'), isFalse);
    });
    test('prefixed без detour "🇷🇺 RU NodeA" → false', () {
      expect(TagResolver.isDetourMarker('🇷🇺 RU NodeA'), isFalse);
    });
    test('пустая строка → false', () {
      expect(TagResolver.isDetourMarker(''), isFalse);
    });
    test('⚙ без trailing space "⚙NodeA" → false', () {
      expect(TagResolver.isDetourMarker('⚙NodeA'), isFalse);
    });
    test('⚙ в начале prefix "⚙Sub Name" → false', () {
      expect(TagResolver.isDetourMarker('⚙Sub Name'), isFalse);
    });
    test('known FP: "My ⚙ Server" → true (декоративный ⚙ — acceptable)', () {
      expect(TagResolver.isDetourMarker('My ⚙ Server'), isTrue);
    });
  });

  group('stripPrefix (reverse)', () {
    test('empty prefix → unchanged', () {
      expect(TagResolver.stripPrefix('M1', ''), 'M1');
    });
    test('matching prefix → stripped', () {
      expect(TagResolver.stripPrefix('🇷🇺 RU M1', '🇷🇺 RU'), 'M1');
    });
    test('non-matching prefix → unchanged', () {
      expect(TagResolver.stripPrefix('Other M1', '🇷🇺 RU'), 'Other M1');
    });
    test('round-trip displayTag → stripPrefix', () {
      const prefix = '🇷🇺 RU';
      const bare = 'M1';
      final display = TagResolver.displayTag(prefix, bare);
      expect(TagResolver.stripPrefix(display, prefix), bare);
    });
  });
}
