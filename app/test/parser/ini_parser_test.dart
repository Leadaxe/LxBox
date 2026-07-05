import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/ini_parser.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

void main() {
  group('parseWireguardIni', () {
    test('fixture ini_basic.conf → WireguardSpec with peer', () {
      final text = File('test/fixtures/wireguard/ini_basic.conf').readAsStringSync();
      final spec = parseWireguardIni(text);
      expect(spec, isNotNull);
      expect(spec!.server, 'example-3.com');
      expect(spec.port, 51820);
      expect(spec.peers, hasLength(1));
      expect(spec.peers.first.publicKey, contains('bbbbbbb'));
      expect(spec.peers.first.preSharedKey, contains('eeeeeee'));
      expect(spec.peers.first.persistentKeepalive, 25);
      expect(spec.mtu, 1420);
      expect(spec.rawIni, contains('[Interface]'));
    });

    test('missing PrivateKey → null', () {
      const ini = '[Interface]\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = p\nEndpoint = h:51820\n';
      expect(parseWireguardIni(ini), isNull);
    });

    test('IPv6 endpoint [::1]:51820 parses', () {
      const ini = '[Interface]\nPrivateKey = pk\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = pubk\nEndpoint = [::1]:51820\n';
      final spec = parseWireguardIni(ini);
      expect(spec, isNotNull);
      expect(spec!.server, '::1');
      expect(spec.port, 51820);
    });
  });

  // §243 — имя файла становится tag'ом через фрагмент синтетического URI.
  group('§243 nameHint → tag', () {
    const ini = '[Interface]\nPrivateKey = pk\nAddress = 10.0.0.2/32\n\n'
        '[Peer]\nPublicKey = pubk\nEndpoint = h:51820\n';

    test('nameHint (имя файла) → tag и label = имя файла', () {
      final spec = parseWireguardIni(ini, nameHint: 'proton-nl-42');
      expect(spec, isNotNull);
      expect(spec!.tag, 'proton-nl-42');
      expect(spec.label, 'proton-nl-42');
    });

    test('без nameHint → прежний фолбэк WireGuard', () {
      expect(parseWireguardIni(ini)!.tag, 'WireGuard');
    });

    test('пустой / пробельный hint → фолбэк WireGuard', () {
      expect(parseWireguardIni(ini, nameHint: '')!.tag, 'WireGuard');
      expect(parseWireguardIni(ini, nameHint: '   ')!.tag, 'WireGuard');
    });

    test('пробел + кириллица + скобки: фрагмент закодирован, round-trip чист',
        () {
      const name = 'Мой сервер (NL) 2';
      final spec = parseWireguardIni(ini, nameHint: name)!;
      expect(spec.tag, name); // не %-энкоженная каша
      // rawUri — валидный URI: фрагмент закодирован, сырых пробелов нет.
      expect(spec.rawUri, isNot(contains(' ')));
      // Симметрия: синтетический URI парсится обратно в тот же tag
      // (это же путь UserServer.fromJson после рестарта).
      final again = parseWireguardUri(spec.rawUri);
      expect(again, isNotNull);
      expect(again!.tag, name);
    });

    test('parseAll: IniConfig получает hint, UriLines его игнорирует', () {
      final iniNodes = parseAll(decode(ini), nameHint: 'from-file');
      expect(iniNodes.single.tag, 'from-file');

      const uriLine =
          'wireguard://PRIV@h:51820?publickey=K&address=10.0.0.2/32';
      final uriNodes = parseAll(decode(uriLine), nameHint: 'from-file');
      expect(uriNodes.single.tag, 'wireguard-h-51820'); // hint не подмешан
    });

    test('parseAll: AmneziaConfig — индексные суффиксы контейнеров', () {
      const ini2 = '[Interface]\nPrivateKey = pk2\nAddress = 10.0.0.3/32\n\n'
          '[Peer]\nPublicKey = pubk2\nEndpoint = h2:51820\n';
      final nodes =
          parseAll(const AmneziaConfig([ini, ini2]), nameHint: 'multi');
      expect(nodes, hasLength(2));
      expect(nodes[0].tag, 'multi');
      expect(nodes[1].tag, 'multi 2');
    });
  });
}
