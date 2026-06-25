import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/builder/post_steps.dart';

/// §172 — деградация битых detour-ссылок: detour на отсутствующий outbound
/// снимается (нода работает напрямую), а не роняет весь конфиг.
void main() {
  group('healDanglingDetours', () {
    test('битый detour ("warp gen") → снят, нода остаётся', () {
      final config = {
        'outbounds': [
          {'tag': '🇫🇮 Finland', 'type': 'vless', 'detour': 'warp gen'},
          {'tag': 'direct-out', 'type': 'direct'},
        ],
      };
      final removed = healDanglingDetours(config);

      expect(removed, hasLength(1));
      expect(removed.single.owner, '🇫🇮 Finland');
      expect(removed.single.target, 'warp gen');
      // нода на месте, но без detour
      final node = (config['outbounds'] as List)[0] as Map;
      expect(node.containsKey('detour'), isFalse, reason: 'detour снят');
      expect(node['tag'], '🇫🇮 Finland', reason: 'нода не выброшена');
      expect((config['outbounds'] as List), hasLength(2));
    });

    test('валидный detour → НЕ трогаем', () {
      final config = {
        'outbounds': [
          {'tag': 'main', 'type': 'vless', 'detour': 'hop'},
          {'tag': 'hop', 'type': 'shadowsocks'},
        ],
      };
      final removed = healDanglingDetours(config);

      expect(removed, isEmpty);
      expect(((config['outbounds'] as List)[0] as Map)['detour'], 'hop');
    });

    test('detour на endpoint (wireguard) → валиден, НЕ трогаем', () {
      final config = {
        'outbounds': [
          {'tag': 'main', 'type': 'vless', 'detour': 'wg-1'},
        ],
        'endpoints': [
          {'tag': 'wg-1', 'type': 'wireguard'},
        ],
      };
      final removed = healDanglingDetours(config);
      expect(removed, isEmpty);
      expect(((config['outbounds'] as List)[0] as Map)['detour'], 'wg-1');
    });

    test('несколько битых detour → все сняты', () {
      final config = {
        'outbounds': [
          {'tag': 'a', 'type': 'vless', 'detour': 'ghost1'},
          {'tag': 'b', 'type': 'vless', 'detour': 'ghost2'},
          {'tag': 'c', 'type': 'vless', 'detour': 'a'}, // валидный
          {'tag': 'direct-out', 'type': 'direct'},
        ],
      };
      final removed = healDanglingDetours(config);

      expect(removed, hasLength(2));
      expect(removed.map((r) => r.target), containsAll(['ghost1', 'ghost2']));
      // валидный detour 'a' остался
      expect(((config['outbounds'] as List)[2] as Map)['detour'], 'a');
      // битые сняты
      expect(((config['outbounds'] as List)[0] as Map).containsKey('detour'),
          isFalse);
      expect(((config['outbounds'] as List)[1] as Map).containsKey('detour'),
          isFalse);
    });

    test('detour на endpoint тоже деградирует если target отсутствует', () {
      final config = {
        'endpoints': [
          {'tag': 'wg-1', 'type': 'wireguard', 'detour': 'ghost'},
        ],
      };
      final removed = healDanglingDetours(config);
      expect(removed, hasLength(1));
      expect(((config['endpoints'] as List)[0] as Map).containsKey('detour'),
          isFalse);
    });

    test('нет detour-полей → no-op', () {
      final config = {
        'outbounds': [
          {'tag': 'a', 'type': 'direct'},
        ],
      };
      expect(healDanglingDetours(config), isEmpty);
    });
  });
}
