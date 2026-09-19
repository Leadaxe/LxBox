import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import 'engine_test_setup.dart';

void main() {
  setUpAll(loadEngineSections);

  test('AWG kind: identity and mtu survive', () {
    const uris = [
      'wireguard://UFJJVkFURUtFWTAwMDAwMDAwMDAwMDAwMDAwMDAwMDA=@wg.example-1.com:51821?publickey=QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU%3D&address=10.10.10.2%2F32&allowedips=0.0.0.0%2F0%2C%3A%3A%2F0&jc=not-a-number&jmin=50#awg-server',
      'wireguard://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=@example-1.com:51820?publickey=AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=&address=10.0.0.2/32&jc=abc&jmin=50#awg-badjc',
      // Контроль: AWG-узел, у которого поля УЦЕЛЕЛИ.
      'awg://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=@example-1.com:51820?publickey=AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=&address=10.0.0.2/32&jc=4&jmin=50&jmax=70#awg-ok',
    ];
    for (final u in uris) {
      final a = parseUri(u)!;
      final link = a.toUri();
      final b = parseUri(link)!;
      // ignore: avoid_print
      print('--- $link');
      // ignore: avoid_print
      print('  identity same=${legacyNodeIdentityHash(a) == legacyNodeIdentityHash(b)} '
          'tag same=${a.tag == b.tag} '
          'mtuA=${a.emitRaw(const TemplateVars()).map['mtu']} '
          'mtuB=${b.emitRaw(const TemplateVars()).map['mtu']}');
    }
  });
}
