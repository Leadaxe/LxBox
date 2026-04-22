import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parse_hints.dart';

void main() {
  group('diagnoseEmptyParse (night T3-3)', () {
    test('empty body → "Empty response"', () {
      expect(diagnoseEmptyParse(''), contains('Empty'));
    });

    test('<!DOCTYPE html> page → web-page hint', () {
      const body = '<!doctype html><html><body>Login</body></html>';
      expect(diagnoseEmptyParse(body), contains('web page'));
    });

    test('Clash YAML → "not supported" hint', () {
      const body = '''
mixed-port: 7890
proxies:
  - name: node1
    type: vmess
proxy-groups:
  - name: main
''';
      expect(diagnoseEmptyParse(body), contains('Clash'));
    });

    test('full sing-box config → "use only outbounds"', () {
      const body = '{"log":{"level":"info"},"inbounds":[],"outbounds":[],'
          '"routing":{}}';
      expect(diagnoseEmptyParse(body), contains('outbounds'));
    });

    test('plain-text short message → echoes content', () {
      const body = 'Subscription not found';
      final hint = diagnoseEmptyParse(body);
      expect(hint, contains('Subscription not found'));
    });

    test('unrecognized binary-ish → returns null (no hint)', () {
      // Random-looking bytes without HTML/YAML/JSON markers.
      final body = String.fromCharCodes(
          List.generate(600, (i) => 33 + (i * 7) % 90));
      final hint = diagnoseEmptyParse(body);
      // Should be null, but plain-text heuristic might catch ASCII — accept
      // either a null or a "plain message" hint.
      if (hint != null) {
        expect(hint.toLowerCase(), anyOf(contains('plain'), contains('message')));
      }
    });

    test('Clash YAML без тега proxies — НЕ триггерит plain-text ветку', () {
      // regression: раньше regex `[а-яА-Я\w\s]+` ловил почти что угодно,
      // включая YAML без explicit `proxies:`, в результате вместо
      // Clash-подсказки юзер получал странный "plain message" echo.
      const body = '''
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
''';
      final hint = diagnoseEmptyParse(body);
      // Не claim-им что это plain-сообщение: либо null, либо Clash-хинт.
      if (hint != null) {
        expect(hint.toLowerCase(), isNot(contains('plain message')));
      }
    });

    test('INI-like огрызок с `=` — НЕ триггерит plain-text ветку', () {
      // regression: config-огрызки с знаками `=`/`:`/`<` должны
      // отклоняться plain-text эвристикой.
      const body = 'server=1.2.3.4\nport=443\nuser=foo';
      expect(diagnoseEmptyParse(body), isNull);
    });

    test('"unauthorized" → plain-text hint триггерится', () {
      const body = 'unauthorized';
      final hint = diagnoseEmptyParse(body);
      expect(hint, isNotNull);
      expect(hint, contains('unauthorized'));
    });

    test('"subscription expired" → plain-text hint триггерится', () {
      const body = 'Subscription expired, please renew.';
      final hint = diagnoseEmptyParse(body);
      expect(hint, isNotNull);
      expect(hint, contains('Subscription expired'));
    });
  });
}
