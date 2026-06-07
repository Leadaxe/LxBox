import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/config/consts.dart';

/// §079 — Unit tests для `isDetourDisplayTag`.
///
/// Helper решает prefix-form ambiguity (см. spec'у §079):
/// `_withPrefix` собирает `'$tagPrefix $base'`, поэтому detour-prefix
/// оказывается в середине строки при непустом subscription tagPrefix.
void main() {
  group('isDetourDisplayTag — true cases', () {
    test('bare-form: tagPrefix=="" → "⚙ NodeName"', () {
      expect(isDetourDisplayTag('⚙ NodeA'), isTrue);
    });

    test('subscription prefix + detour: "🇷🇺 RU ⚙ NodeName"', () {
      expect(isDetourDisplayTag('🇷🇺 RU ⚙ HopB'), isTrue);
    });

    test('ASCII subscription prefix: "SUB ⚙ NodeA"', () {
      expect(isDetourDisplayTag('SUB ⚙ NodeA'), isTrue);
    });

    test('collision-suffix не ломает детект: "🇷🇺 RU ⚙ HopB-1"', () {
      expect(isDetourDisplayTag('🇷🇺 RU ⚙ HopB-1'), isTrue);
    });

    test('multi-word subscription prefix: "My Prefix ⚙ Hop"', () {
      expect(isDetourDisplayTag('My Prefix ⚙ Hop'), isTrue);
    });
  });

  group('isDetourDisplayTag — false cases', () {
    test('plain bare node', () {
      expect(isDetourDisplayTag('NodeA'), isFalse);
    });

    test('subscription prefix без detour: "🇷🇺 RU NodeA"', () {
      expect(isDetourDisplayTag('🇷🇺 RU NodeA'), isFalse);
    });

    test('пустая строка', () {
      expect(isDetourDisplayTag(''), isFalse);
    });

    test('одиночный ⚙ без trailing space (не префикс) → false', () {
      // kDetourTagPrefix == '⚙ ' (with trailing space). Сам по себе
      // символ ⚙ как часть имени без trailing space не маркер detour'а.
      expect(isDetourDisplayTag('⚙NodeA'), isFalse);
    });

    test('⚙ в начале tagPrefix но не как detour: ' ' "⚙Sub Name"', () {
      // Подписка с tagPrefix='⚙Sub' (no space) — `_withPrefix` даст
      // '⚙Sub Name'. Не должно считаться detour-сервером.
      // (Гипотетический edge — реальные tagPrefix'ы с ⚙ редкость.)
      expect(isDetourDisplayTag('⚙Sub Name'), isFalse);
    });
  });

  group('isDetourDisplayTag — known false-positives (документация)', () {
    test('юзер с ⚙ в середине имени НОДЫ — known FP (см. spec)', () {
      // Если юзер назвал ноду 'My ⚙ Server' (декоративный ⚙ в имени),
      // helper посчитает её detour'ом. Spec явно decmes этот edge
      // acceptable — ⚙ функциональный маркер detour-семантики.
      expect(isDetourDisplayTag('My ⚙ Server'), isTrue);
    });
  });
}
