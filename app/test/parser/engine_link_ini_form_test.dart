import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/engine/interpreter.dart';
import 'package:lxbox/services/parser/engine/section.dart';

/// Ссылочная форма с пространством `ini` (`<схема>://<base64 .conf>#метка`)
/// исполняется движком: фрагмент снимается до `detect`, раскрытый текст
/// раскладывается диалектом секции, метка идёт цепочкой `label.source`
/// формы, включая путь тела. Секция синтетическая, тип тела `probe`.
MapperSection _section() => MapperSection.fromJson('uri', 'probe', {
      'body_source': 'uri',
      'forms': [
        {
          'id': 'conf_b64',
          'detect': {
            'all': [
              {
                'not': {
                  'text': {'contains': '@'},
                },
              },
              {'regex': r'^[A-Za-z0-9+/=_-]+\s*$'},
            ],
          },
          'decode': [
            {'decoder': 'base64', 'scope': 'authority'},
            'ini',
          ],
          'space': 'ini',
        },
        {
          'id': 'url',
          'detect': {'default': true},
          'space': 'url',
        },
      ],
      'ini_dialect': {'key_case': 'lower', 'value_case': 'preserve'},
      'label': {
        'source': {
          'url': ['fragment'],
          'conf_b64': ['fragment', r'ini.$comment.Peer', 'peers[].address'],
        },
      },
      'params': {
        'key': {
          'source': {'url': 'userinfo', 'conf_b64': 'ini.Interface.Key'},
          'maps_to': 'key',
          'required': true,
        },
        'host': {
          'source': {'url': 'host', 'conf_b64': 'ini.Peer.Host'},
          'maps_to': 'peers[].address',
        },
      },
    });

String _link(String conf, [String frag = '']) =>
    'x://${base64.encode(utf8.encode(conf))}${frag.isEmpty ? '' : '#$frag'}';

void main() {
  const conf = '[Interface]\nKey = k1\n[Peer]\nHost = h.example\n';

  test('ini-форма ссылки читается движком, фрагмент — метка', () {
    final res = runSection(_section(), _link(conf, 'My%20Node'));
    expect(res, isNotNull);
    expect(res!.body['key'], 'k1');
    expect(res.label, 'My Node');
  });

  test('без фрагмента метка — путь тела из цепочки формы', () {
    final res = runSection(_section(), _link(conf));
    expect(res?.label, 'h.example');
  });

  test('раскрытый текст без обязательного поля — не узел', () {
    expect(runSection(_section(), _link('hello, not a conf')), isNull);
  });

  test('ссылка со структурой authority идёт ссылочной формой', () {
    final res = runSection(_section(), 'x://k2@h2.example:1#n');
    expect(res?.body['key'], 'k2');
  });
}
