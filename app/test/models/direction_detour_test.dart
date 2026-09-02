import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/direction.dart';

/// §248/§274 — parse-гейт detour-инвариантов в Direction.fromJson: restore из
/// backup и ручная правка файла пишут raw JSON мимо UI/storage/API — read-time
/// коэрс единственная точка, которую не обойти. После §274 гейт остался один:
/// «vpn-1 не detour». Комбинация detour × include_block легальна — detour
/// теперь разрешение, а не роль-исключение.
void main() {
  group('§248/§274 — Direction.fromJson parse-гейт', () {
    test('vpn-1 + detour:true → isDetour коэрсится в false', () {
      final c = Direction.fromJson({
        'tag': 'vpn-1',
        'label': 'Main',
        'detour': true,
      });
      expect(c.isDetour, false);
    });

    test('detour:true + include_block:true → оба поля true (легально, §274)',
        () {
      final c = Direction.fromJson({
        'tag': 'vpn-2',
        'label': 'Relay',
        'detour': true,
        'include_block': true,
      });
      expect(c.isDetour, true);
      expect(c.includeBlock, true);
    });

    test('обычное Направление: detour отсутствует → false, include_block живёт',
        () {
      final c = Direction.fromJson({
        'tag': 'vpn-2',
        'label': 'X',
        'include_block': true,
      });
      expect(c.isDetour, false);
      expect(c.includeBlock, true);
    });

    test('toJson↔fromJson roundtrip сохраняет detour + include_block (§274)',
        () {
      const src = Direction(
        tag: 'vpn-2',
        isDetour: true,
        includeBlock: true,
      );
      final back = Direction.fromJson(src.toJson());
      expect(back.isDetour, true);
      expect(back.includeBlock, true);
    });

    test('copyWith(isDetour:) переключает роль', () {
      const c = Direction(tag: 'vpn-2');
      expect(c.copyWith(isDetour: true).isDetour, true);
      expect(c.copyWith(isDetour: true).copyWith(isDetour: false).isDetour,
          false);
      // copyWith без параметра не трогает роль.
      expect(c.copyWith().isDetour, false);
    });
  });

  // Контракт 0.9.0 — ⚙ больше НЕ живёт в данных: имя Направления = его tag,
  // а маркер detour-мишени вычисляется над тегом в displayLabel.
  group('displayLabel: ⚙ производный над tag', () {
    test('detour → префикс ⚙ перед tag', () {
      const c = Direction(tag: 'vpn-2', isDetour: true);
      expect(c.displayLabel, '${kDetourTagPrefix}vpn-2');
    });

    test('не detour → голый tag, без префикса', () {
      const c = Direction(tag: 'vpn-2');
      expect(c.displayLabel, 'vpn-2');
    });

    test('storage roundtrip: ⚙ в данные не пишется', () {
      const c = Direction(tag: 'vpn-2', isDetour: true);
      expect(c.toJson().containsKey('label'), false);
      final back = Direction.fromJson(c.toJson());
      expect(back.displayLabel, '${kDetourTagPrefix}vpn-2');
      expect(back.isDetour, true);
    });

    test('legacy-ключ label из старого состояния отбрасывается', () {
      final c = Direction.fromJson(
          {'tag': 'vpn-2', 'label': 'Relay', 'detour': true});
      expect(c.displayLabel, '${kDetourTagPrefix}vpn-2');
    });
  });
}
