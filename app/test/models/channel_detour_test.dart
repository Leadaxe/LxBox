import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/channel.dart';

/// §248 — parse-гейт detour-инвариантов в Channel.fromJson: restore из backup
/// и ручная правка файла пишут raw JSON мимо UI/storage/API — read-time
/// коэрс единственная точка, которую не обойти.
void main() {
  group('§248 — Channel.fromJson parse-гейт', () {
    test('vpn-1 + detour:true → isDetour коэрсится в false', () {
      final c = Channel.fromJson({
        'tag': 'vpn-1',
        'label': 'Main',
        'detour': true,
      });
      expect(c.isDetour, false);
    });

    test('detour:true + include_block:true → includeBlock коэрсится в false',
        () {
      final c = Channel.fromJson({
        'tag': 'vpn-2',
        'label': 'Relay',
        'detour': true,
        'include_block': true,
      });
      expect(c.isDetour, true);
      expect(c.includeBlock, false);
    });

    test('обычный канал: detour отсутствует → false, include_block живёт',
        () {
      final c = Channel.fromJson({
        'tag': 'vpn-2',
        'label': 'X',
        'include_block': true,
      });
      expect(c.isDetour, false);
      expect(c.includeBlock, true);
    });

    test('toJson↔fromJson roundtrip сохраняет detour', () {
      const src = Channel(tag: 'vpn-2', label: 'Relay', isDetour: true);
      final back = Channel.fromJson(src.toJson());
      expect(back.isDetour, true);
      expect(back.includeBlock, false);
    });

    test('copyWith(isDetour:) переключает роль', () {
      const c = Channel(tag: 'vpn-2', label: 'X');
      expect(c.copyWith(isDetour: true).isDetour, true);
      expect(c.copyWith(isDetour: true).copyWith(isDetour: false).isDetour,
          false);
      // copyWith без параметра не трогает роль.
      expect(c.copyWith(label: 'Y').isDetour, false);
    });
  });
}
