import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/node_emoji.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §090 G2b — unit tests для эмодзи-тегов (палитра / hasEmoji / дефолт по
/// протоколу / вставка в rawBody с round-trip через парсер).
void main() {
  NodeSpec parse(String uri) => parseUri(uri)!;

  WireguardSpec wg({String server = '5.6.7.8'}) => WireguardSpec(
        id: '1',
        tag: 'wg-node',
        label: 'wg',
        server: server,
        port: 51820,
        rawUri: '',
        privateKey: 'k',
        localAddresses: const [],
        peers: const [],
      );

  group('hasEmoji', () {
    test('detects pictographic + flags, false для plain', () {
      expect(hasEmoji('🏠 Home'), isTrue);
      expect(hasEmoji('⚡ Fast'), isTrue);
      expect(hasEmoji('🇷🇺 RU'), isTrue); // regional-indicator pair
      expect(hasEmoji('PlainName'), isFalse);
      expect(hasEmoji('M1-2'), isFalse);
    });
  });

  group('defaultEmojiFor — приоритет local → WG → UDP → TCP', () {
    test('vless (TCP) → ⚡', () {
      expect(defaultEmojiFor(parse('vless://uuid@1.2.3.4:443?security=none#X')),
          '⚡');
    });
    test('hysteria2 (UDP/QUIC) → 🚀', () {
      expect(
          defaultEmojiFor(parse('hysteria2://hp@hy2.example:443?sni=hy2.example#Hy2')),
          '🚀');
    });
    test('tuic (UDP/QUIC) → 🚀', () {
      expect(
          defaultEmojiFor(parse(
              'tuic://u:p@h.example:443?congestion_control=bbr&alpn=h3&sni=h.example#TUIC')),
          '🚀');
    });
    test('wireguard → 🏠', () {
      expect(defaultEmojiFor(wg()), '🏠');
    });
    test('local 127.0.0.1 → 🔁 (приоритет над протоколом)', () {
      expect(
          defaultEmojiFor(parse('vless://uuid@127.0.0.1:443?security=none#X')),
          '🔁');
      expect(defaultEmojiFor(wg(server: '127.0.0.1')), '🔁'); // local > WG
    });
    test('localhost → 🔁', () {
      expect(
          defaultEmojiFor(parse('vless://uuid@localhost:443?security=none#X')),
          '🔁');
    });
  });

  group('withDefaultEmoji / prependEmojiToRawBody — round-trip через парсер', () {
    test('URI без эмодзи → tag получает дефолт (re-parse подтверждает)', () {
      const uri = 'vless://uuid@1.2.3.4:443?security=none#MyServer';
      final node = parse(uri);
      final out = withDefaultEmoji(uri, node);
      expect(out, isNot(uri)); // изменился
      expect(parse(out).tag.startsWith('⚡'), isTrue);
      expect(parse(out).tag.contains('MyServer'), isTrue);
    });

    test('URI уже с эмодзи в имени → без изменений', () {
      const uri = 'vless://uuid@1.2.3.4:443?security=none#${'🏠'} Home';
      final node = parse(uri);
      expect(withDefaultEmoji(uri, node), uri);
    });

    test('hysteria2 → 🚀 в теге', () {
      const uri = 'hysteria2://hp@hy2.example:443?sni=hy2.example#Hy2';
      final out = withDefaultEmoji(uri, parse(uri));
      expect(parse(out).tag.startsWith('🚀'), isTrue);
    });

    test('JSON-outbound: tag получает эмодзи', () {
      const json =
          '{"type":"vless","tag":"JNode","server":"1.2.3.4","server_port":443,'
          '"uuid":"00000000-0000-0000-0000-000000000000"}';
      final out = prependEmojiToRawBody(json, '🔁');
      expect(out.contains('🔁 JNode'), isTrue);
    });

    test('JSON уже с эмодзи → без изменений', () {
      const json = '{"type":"vless","tag":"🏠 J","server":"1.2.3.4",'
          '"server_port":443,"uuid":"00000000-0000-0000-0000-000000000000"}';
      expect(prependEmojiToRawBody(json, '⚡'), json);
    });

    test('idempotent: повторная вставка не дублирует', () {
      const uri = 'vless://uuid@1.2.3.4:443?security=none#MyServer';
      final once = withDefaultEmoji(uri, parse(uri));
      final twice = withDefaultEmoji(once, parse(once));
      expect(twice, once);
    });
  });

  test('палитра содержит ожидаемые эмодзи', () {
    expect(kEmojiPalette, containsAll(<String>['🏠', '⚡', '🚀', '🔁', '⚙']));
  });
}
