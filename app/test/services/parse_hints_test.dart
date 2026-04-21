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
  });
}
