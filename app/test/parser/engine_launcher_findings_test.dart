import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import 'engine_test_setup.dart';

/// §492 — дефекты движка, найденные лаунчером на том же реестре.
///
/// Живые входы (ссылка, тело подписки) — здесь; синтетические примитивы
/// (`merge`, `label.value_map`, `on_len_gt`) — в `engine_primitives_test`.
void main() {
  setUpAll(loadEngineSections);

  const links = 'vless://11111111-2222-3333-4444-555555555555@h.example:443#a\n'
      'trojan://pw@h.example:443#b\n';

  String wrap(String s) => base64.encode(utf8.encode(s));

  group('merge append — два писателя в один путь-список', () {
    test('authority и mport оба доезжают в server_ports', () {
      // Реестр: `$multiport` читает диапазон из authority, `mport` — из
      // query, `merge: append`. Форма ядра — `low:high`.
      final spec = parseUri(
        'hysteria2://pw@h.example:20000-30000'
        '?mport=40000-50000&sni=x.example#n',
      );
      expect(spec, isA<Hysteria2Spec>());
      expect((spec as Hysteria2Spec).serverPorts, ['20000:30000', '40000:50000']);
    });
  });

  group('base64-обёртка подписки — глубина unwrap', () {
    test('1× — список ссылок', () {
      final nodes = parseAll(decode(wrap(links)));
      expect(nodes, hasLength(2));
    });

    test('1× — одиночная ссылка', () {
      const inner = 'trojan://pw@h.example:443#a';
      expect((decode(wrap(inner)) as UriLines).lines.single, inner);
    });

    test('2× — снимается до ссылок', () {
      final nodes = parseAll(decode(wrap(wrap(links))));
      expect(nodes, hasLength(2));
    });

    test('2× — одиночная ссылка', () {
      const inner = 'trojan://pw@h.example:443#a';
      expect((decode(wrap(wrap(inner))) as UriLines).lines.single, inner);
    });

    test('3× — тихий отказ, узлов нет, без исключения', () {
      final body = wrap(wrap(wrap(links)));
      expect(() => decode(body), returnsNormally);
      expect(() => parseAll(decode(body)), returnsNormally);
      expect(parseAll(decode(body)), isEmpty);
    });
  });

  group('BOM в начале текста не мешает виду источника', () {
    const bom = '\uFEFF';

    test('JSON', () {
      final r = decode(
        '$bom{"log":{},"outbounds":[{"type":"trojan",'
        '"server":"h.example","server_port":443,"password":"p"}]}',
      );
      expect(r, isA<JsonConfig>());
      expect((r as JsonConfig).source.kind, SourceKind.singboxConfig);
    });

    test('base64-обёртка', () {
      final r = decode('$bom${wrap(links)}');
      expect(r, isA<UriLines>());
      expect((r as UriLines).lines, hasLength(2));
    });

    test('ссылки', () {
      final r = decode('$bom$links');
      expect(r, isA<UriLines>());
      expect((r as UriLines).lines, hasLength(2));
    });

    test('INI', () {
      final r = decode(
        '$bom[Interface]\nPrivateKey = aaa\nAddress = 10.0.0.2/32\n'
        '[Peer]\nPublicKey = bbb\nEndpoint = h.example:51820\n',
      );
      expect(r, isA<IniConfig>());
    });
  });
}
