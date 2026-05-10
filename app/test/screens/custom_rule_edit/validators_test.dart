import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/custom_rule_edit/validators.dart';

/// §053 Stage 1 — unit tests для extracted validators.
/// До extract'а эти функции были private в CustomRuleEditScreen и не
/// тестировались. Pure-function форма позволяет full coverage.
void main() {
  group('isValidDomain', () {
    test('accepts standard FQDN', () {
      expect(isValidDomain('example.com'), isTrue);
      expect(isValidDomain('sub.example.com'), isTrue);
      expect(isValidDomain('multi.level.sub.example.co.uk'), isTrue);
    });
    test('accepts hyphenated labels', () {
      expect(isValidDomain('my-site.com'), isTrue);
      expect(isValidDomain('a-b-c.d-e-f.io'), isTrue);
    });
    test('rejects bare TLD / single label', () {
      expect(isValidDomain('com'), isFalse);
      expect(isValidDomain('localhost'), isFalse);
    });
    test('rejects IP address', () {
      expect(isValidDomain('192.168.1.1'), isFalse);
    });
    test('rejects empty / whitespace', () {
      expect(isValidDomain(''), isFalse);
      expect(isValidDomain('   '), isFalse);
    });
    test('rejects URL with scheme', () {
      expect(isValidDomain('https://example.com'), isFalse);
    });
    test('rejects label starting/ending with hyphen', () {
      expect(isValidDomain('-bad.com'), isFalse);
      expect(isValidDomain('bad-.com'), isFalse);
    });
  });

  group('isValidKeyword', () {
    test('accepts non-empty without whitespace', () {
      expect(isValidKeyword('tracker'), isTrue);
      expect(isValidKeyword('analytics'), isTrue);
      expect(isValidKeyword('a'), isTrue);
    });
    test('rejects empty', () {
      expect(isValidKeyword(''), isFalse);
    });
    test('rejects whitespace inside', () {
      expect(isValidKeyword('two words'), isFalse);
      expect(isValidKeyword('tab\there'), isFalse);
    });
  });

  group('isValidCidr', () {
    test('accepts IPv4 CIDR', () {
      expect(isValidCidr('10.0.0.0/8'), isTrue);
      expect(isValidCidr('192.168.1.0/24'), isTrue);
      expect(isValidCidr('1.2.3.4/32'), isTrue);
      expect(isValidCidr('0.0.0.0/0'), isTrue);
    });
    test('accepts IPv6 CIDR', () {
      expect(isValidCidr('::1/128'), isTrue);
      expect(isValidCidr('fe80::/10'), isTrue);
      expect(isValidCidr('2001:db8::/32'), isTrue);
    });
    test('rejects missing mask', () {
      expect(isValidCidr('192.168.1.0'), isFalse);
      expect(isValidCidr('::1'), isFalse);
    });
    test('rejects mask out of range', () {
      expect(isValidCidr('1.2.3.4/33'), isFalse);
      expect(isValidCidr('::1/129'), isFalse);
      expect(isValidCidr('1.2.3.4/-1'), isFalse);
    });
    test('rejects octet > 255', () {
      expect(isValidCidr('256.0.0.0/8'), isFalse);
      expect(isValidCidr('1.2.3.999/24'), isFalse);
    });
    test('rejects malformed', () {
      expect(isValidCidr('foo'), isFalse);
      expect(isValidCidr('1.2.3/24'), isFalse);
      expect(isValidCidr('//24'), isFalse);
    });
  });

  group('isValidPort', () {
    test('accepts valid range', () {
      expect(isValidPort('0'), isTrue);
      expect(isValidPort('80'), isTrue);
      expect(isValidPort('443'), isTrue);
      expect(isValidPort('65535'), isTrue);
    });
    test('rejects out of range', () {
      expect(isValidPort('65536'), isFalse);
      expect(isValidPort('-1'), isFalse);
    });
    test('rejects non-numeric', () {
      expect(isValidPort('abc'), isFalse);
      expect(isValidPort(''), isFalse);
      expect(isValidPort('80.0'), isFalse);
    });
  });

  group('isValidPortRange', () {
    test('accepts full range', () {
      expect(isValidPortRange('8000:9000'), isTrue);
    });
    test('accepts open-low', () {
      expect(isValidPortRange(':3000'), isTrue);
    });
    test('accepts open-high', () {
      expect(isValidPortRange('4000:'), isTrue);
    });
    test('rejects both empty', () {
      expect(isValidPortRange(':'), isFalse);
    });
    test('rejects lo > hi', () {
      expect(isValidPortRange('9000:8000'), isFalse);
    });
    test('rejects no colon', () {
      expect(isValidPortRange('80'), isFalse);
    });
    test('rejects out of range', () {
      expect(isValidPortRange('70000:80000'), isFalse);
    });
  });

  group('isValidUrl', () {
    test('accepts http/https with host', () {
      expect(isValidUrl('http://example.com'), isTrue);
      expect(isValidUrl('https://example.com/path?q=1'), isTrue);
    });
    test('rejects other schemes', () {
      expect(isValidUrl('ftp://example.com'), isFalse);
      expect(isValidUrl('file:///etc/hosts'), isFalse);
    });
    test('rejects missing host', () {
      expect(isValidUrl('https://'), isFalse);
      expect(isValidUrl('http:///path'), isFalse);
    });
    test('rejects empty / garbage', () {
      expect(isValidUrl(''), isFalse);
      expect(isValidUrl('not a url'), isFalse);
    });
  });

  group('isValidBssid (§051)', () {
    test('accepts canonical lower-case', () {
      expect(isValidBssid('38:2c:4a:cf:6d:5c'), isTrue);
    });
    test('accepts upper-case (caller normalizes)', () {
      expect(isValidBssid('38:2C:4A:CF:6D:5C'), isTrue);
    });
    test('accepts mixed case', () {
      expect(isValidBssid('Aa:Bb:Cc:Dd:Ee:Ff'), isTrue);
    });
    test('accepts empty (chip может быть только с SSID)', () {
      expect(isValidBssid(''), isTrue);
    });
    test('rejects wrong-length octet', () {
      expect(isValidBssid('38:2c:4a:cf:6d:5'), isFalse);
      expect(isValidBssid('038:2c:4a:cf:6d:5c'), isFalse);
    });
    test('rejects wrong segment count', () {
      expect(isValidBssid('38:2c:4a:cf:6d'), isFalse);
      expect(isValidBssid('38:2c:4a:cf:6d:5c:00'), isFalse);
    });
    test('rejects non-hex chars', () {
      expect(isValidBssid('zz:2c:4a:cf:6d:5c'), isFalse);
    });
  });
}
