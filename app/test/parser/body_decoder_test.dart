import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/body_decoder.dart';

void main() {
  group('decode', () {
    test('plain URI list', () {
      final r = decode('vless://x@h:1#a\nss://x@h:1#b\n\n# comment\n');
      expect(r, isA<UriLines>());
      expect((r as UriLines).lines, hasLength(2));
      expect(r.skippedComments, 1);
    });

    test('base64-wrapped URI list', () {
      final raw = 'vless://x@h:1#a\ntrojan://p@h:2#b\n';
      final b64 = base64.encode(utf8.encode(raw));
      final r = decode(b64);
      expect(r, isA<UriLines>());
      expect((r as UriLines).lines, hasLength(2));
    });

    test('INI config', () {
      const ini = '[Interface]\nPrivateKey = x\n\n[Peer]\nPublicKey = y\nEndpoint = h:51820\n';
      final r = decode(ini);
      expect(r, isA<IniConfig>());
    });

    test('JSON singbox outbound', () {
      final r = decode('{"type":"vless","server":"h","server_port":443,"uuid":"u"}');
      expect(r, isA<JsonConfig>());
      expect((r as JsonConfig).flavor, JsonFlavor.singboxOutbound);
    });

    test('Xray JSON array', () {
      final r = decode('[{"outbounds":[{"protocol":"vless","tag":"proxy"}]}]');
      expect(r, isA<JsonConfig>());
      expect((r as JsonConfig).flavor, JsonFlavor.xrayArray);
    });

    test('empty body → failure', () {
      expect(decode(''), isA<DecodeFailure>());
      expect(decode('   \n\n'), isA<DecodeFailure>());
    });

    test('comment-only → failure', () {
      expect(decode('# nothing\n// zilch'), isA<DecodeFailure>());
    });
  });
}
