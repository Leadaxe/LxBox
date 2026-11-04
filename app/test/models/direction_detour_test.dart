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
  });

  // §274 — ⚙ живёт в самом label (storage), как ⚙-метка в тегах
  // detour-серверов: смена флага через copyWith переименовывает Направление,
  // fromJson нормализует restore/ручную правку. Руками маркер не снять —
  // нормализация вернёт (⚙ зарезервирован).
  group('§274 — normalizeLabel: ⚙ в storage-label', () {
    test('copyWith(isDetour:true) переименовывает label в ⚙-форму', () {
      const c = Direction(tag: 'vpn-2', label: 'Relay');
      final d = c.copyWith(isDetour: true);
      expect(d.label, '${kDetourTagPrefix}Relay');
    });

    test('copyWith(isDetour:false) срезает префикс', () {
      const c = Direction(
          tag: 'vpn-2', label: '${kDetourTagPrefix}Relay', isDetour: true);
      final d = c.copyWith(isDetour: false);
      expect(d.label, 'Relay');
    });

    test('юзер стёр ⚙ при включённой галке → copyWith возвращает префикс',
        () {
      const c = Direction(
          tag: 'vpn-2', label: '${kDetourTagPrefix}Relay', isDetour: true);
      final d = c.copyWith(label: 'Relay');
      expect(d.label, '${kDetourTagPrefix}Relay');
    });

    test('fromJson нормализует: detour:true без ⚙ в label (правленый backup)',
        () {
      final c = Direction.fromJson(
          {'tag': 'vpn-2', 'label': 'Relay', 'detour': true});
      expect(c.label, '${kDetourTagPrefix}Relay');
    });

    test('fromJson срезает ⚙ у не-detour Направления (маркер зарезервирован)',
        () {
      final c = Direction.fromJson(
          {'tag': 'vpn-2', 'label': '${kDetourTagPrefix}Relay'});
      expect(c.label, 'Relay');
    });

    test('пустой label не трогается (display-фолбэк на tag в displayLabel)',
        () {
      const c = Direction(tag: 'vpn-2', label: '', isDetour: true);
      expect(c.copyWith(nodeFilter: 'x').label, '');
    });

    test('storage roundtrip: label с ⚙ стабилен (без второго префикса)', () {
      const c = Direction(
          tag: 'vpn-2', label: '${kDetourTagPrefix}Relay', isDetour: true);
      final back = Direction.fromJson(c.toJson());
      expect(back.label, '${kDetourTagPrefix}Relay');
      expect(back.isDetour, true);
    });
  });
}
