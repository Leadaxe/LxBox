import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/custom_rule_edit/punycode.dart';

/// §144 — Punycode (RFC 3492) + per-label IDNA ToASCII.
void main() {
  group('punycodeEncode (RFC 3492 §7.1 reference vectors)', () {
    // Эталонные строки из RFC 3492 — без `xn--` префикса.
    test('arabic (egyptian)', () {
      expect(punycodeEncode('ليهمابتكلموشعربي؟'),
          'egbpdaj6bu4bxfgehfvwxn');
    });
    test('chinese — «почему не говорят по-китайски»', () {
      expect(punycodeEncode('他们为什么不说中文'),
          'ihqwcrb4cv8a8dqg056pqjye');
    });
    test('russian — «почему они не говорят по-русски»', () {
      expect(punycodeEncode('почемужеонинеговорятпорусски'),
          'b1abfaaepdrnnbgefbadotcwatmq2g4l');
    });
    test('german — Bahnhof München', () {
      expect(punycodeEncode('münchen'), 'mnchen-3ya');
    });
  });

  group('domainToAscii (per-label)', () {
    test('.рф → xn--p1ai', () {
      expect(domainToAscii('рф'), 'xn--p1ai');
    });
    test('multi-label cyrillic', () {
      expect(domainToAscii('мвд.рф'), 'xn--b1aew.xn--p1ai');
      expect(domainToAscii('почта.рф'), 'xn--80a1acny.xn--p1ai');
    });
    test('mixed ASCII + IDN labels — только не-ASCII кодируется', () {
      expect(domainToAscii('shop.рф'), 'shop.xn--p1ai');
      expect(domainToAscii('münchen.de'), 'xn--mnchen-3ya.de');
    });
    test('cjk', () {
      expect(domainToAscii('日本'), 'xn--wgv71a');
    });
    test('pure-ASCII passthrough (fast-path)', () {
      expect(domainToAscii('example.com'), 'example.com');
      expect(domainToAscii('co.uk'), 'co.uk');
      expect(domainToAscii('xn--p1ai'), 'xn--p1ai'); // уже punycode
    });
    test('empty / empty labels', () {
      expect(domainToAscii(''), '');
      expect(domainToAscii('.рф'), '.xn--p1ai'); // leading dot сохраняется
    });
  });
}
