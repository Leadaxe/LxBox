import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/parser/source_name.dart';

import 'engine_test_setup.dart';

// `vpn://<base64>#имя` читается по той же схеме, что `awg://<base64>#имя`.

final _key = base64.encode(List<int>.filled(32, 7));
String _ini(String host) => '[Interface]\nPrivateKey = $_key\n'
    'Address = 10.8.1.4/32\n\n[Peer]\n# FromPeer\nPublicKey = $_key\n'
    'AllowedIPs = 0.0.0.0/0\nEndpoint = $host:666\n';

String _b64(String text) =>
    base64Url.encode(utf8.encode(text)).replaceAll('=', '');

final _bare = _b64(_ini('a.example.com'));

final _profile = _b64(jsonEncode({
  'description': 'Profile',
  'defaultContainer': 'amnezia-awg2',
  'containers': [
    for (final (name, host) in [
      ('amnezia-awg', 'a.example.com'),
      ('amnezia-awg2', 'b.example.com'),
    ])
      {
        'container': name,
        'awg': {
          'last_config': jsonEncode({'config': _ini(host)}),
        },
      },
  ],
}));

const _other = 'trojan://pw@h.example:443#other';

List<String> _tags(String text) =>
    [for (final n in parseAll(decode(text))) n.tag];

void main() {
  setUpAll(loadEngineSections);

  const fragment = '#%D0%98%D0%BC%D1%8F%20%D1%83%D0%B7%D0%BB%D0%B0';

  test('голый .conf: имя как у awg://, одиночной ссылкой и строкой списка', () {
    for (final scheme in ['awg', 'vpn']) {
      expect(_tags('$scheme://$_bare$fragment'), ['Имя узла'], reason: scheme);
      expect(_tags('$scheme://$_bare$fragment\n$_other'), ['Имя узла', 'other'],
          reason: scheme);
    }
  });

  test('без имени — как прежде, из комментария под [Peer]', () {
    for (final text in ['vpn://$_bare', 'vpn://$_bare#']) {
      expect(_tags(text), ['FromPeer'], reason: text);
    }
  });

  test('профиль: имя ссылки заменяет имя профиля, тело и список равны', () {
    const expected = ['Mine amnezia-awg', 'Mine'];
    expect(_tags('vpn://$_profile#Mine'), expected);
    expect(_tags('vpn://$_profile#Mine\n$_other'), [...expected, 'other']);
  });

  test('имя, изменённое в тексте ссылки, видно как правка имени', () {
    expect(nameWrittenByEdit('vpn://$_bare', 'vpn://$_bare#New'), 'New');
    expect(nameWrittenByEdit('vpn://$_bare#New', 'vpn://$_bare'), isNull);
  });
}
