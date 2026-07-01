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
    test('vpn:// → false (Amnezia-контейнер, не direct link, §110)', () {
      expect(isDirectLink('vpn://abc'), isFalse);
    });
    test('trimmed leading space', () {
      expect(isDirectLink('   vmess://xxx'), isTrue);
    });
  });

  group('isAmneziaVpnLink (§110)', () {
    test('vpn://… → true', () {
      expect(isAmneziaVpnLink('vpn://AAAA'), isTrue);
    });
    test('leading whitespace → trimmed', () {
      expect(isAmneziaVpnLink('  vpn://AAAA '), isTrue);
    });
    test('vless:// → false', () {
      expect(isAmneziaVpnLink('vless://u@h:443'), isFalse);
    });
    test('пустая строка → false', () {
      expect(isAmneziaVpnLink(''), isFalse);
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

  group('§129 isFileSubscription', () {
    test('file:<uuid> → true', () {
      expect(isFileSubscription('file:abc-123'), isTrue);
    });
    test('https:// → false', () {
      expect(isFileSubscription('https://p.example/sub'), isFalse);
    });
    test('пустой → false', () {
      expect(isFileSubscription(''), isFalse);
    });
    test('file без двоеточия (случайное) — по префиксу true', () {
      // Дискриминатор — строгий префикс `file:`; `filename` не матчит.
      expect(isFileSubscription('filename.txt'), isFalse);
    });
  });
}
