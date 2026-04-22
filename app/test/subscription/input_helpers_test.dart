import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/subscription/input_helpers.dart';

void main() {
  group('isSubscriptionUrl (night T5-3)', () {
    test('https URL → true', () {
      expect(isSubscriptionUrl('https://p.example/sub'), isTrue);
    });
    test('http URL → true', () {
      expect(isSubscriptionUrl('http://p.example/sub'), isTrue);
    });
    test('с leading whitespace → trimmed', () {
      expect(isSubscriptionUrl('  https://x/ '), isTrue);
    });
    test('vless:// → false (direct link)', () {
      expect(isSubscriptionUrl('vless://u@h:443'), isFalse);
    });
    test('плейн-текст → false', () {
      expect(isSubscriptionUrl('some payload'), isFalse);
    });
    test('пустая строка → false', () {
      expect(isSubscriptionUrl(''), isFalse);
    });
  });

  group('isDirectLink (night T5-3)', () {
    final schemes = {
      'vless': 'vless://u@h:443',
      'vmess': 'vmess://base64payload',
      'trojan': 'trojan://p@h:443',
      'ss': 'ss://enc@h:443',
      'hysteria2': 'hysteria2://p@h:443',
      'hy2': 'hy2://p@h:443',
      'tuic': 'tuic://u:p@h:443',
      'ssh': 'ssh://u@h:22',
      'wireguard': 'wireguard://...',
      'wg': 'wg://...',
      'socks5': 'socks5://u:p@h:1080',
      'socks': 'socks://h:1080',
    };
    for (final e in schemes.entries) {
      test('${e.key}:// → true', () {
        expect(isDirectLink(e.value), isTrue);
      });
    }
    test('https → false (subscription, not direct)', () {
      expect(isDirectLink('https://x/sub'), isFalse);
    });
    test('trimmed leading space', () {
      expect(isDirectLink('   vmess://xxx'), isTrue);
    });
  });

  group('isWireGuardConfig (night T5-3)', () {
    test('полный wg-конфиг → true', () {
      const cfg = '[Interface]\nPrivateKey = x\n[Peer]\nPublicKey = y';
      expect(isWireGuardConfig(cfg), isTrue);
    });
    test('только [Interface] → false', () {
      expect(isWireGuardConfig('[Interface]\nPrivateKey = x'), isFalse);
    });
    test('только [Peer] → false', () {
      expect(isWireGuardConfig('[Peer]\nPublicKey = x'), isFalse);
    });
    test('пустой → false', () {
      expect(isWireGuardConfig(''), isFalse);
    });
  });
}
