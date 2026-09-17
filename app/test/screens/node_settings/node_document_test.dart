import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/node_settings/node_document.dart';

/// §435 — подготовка текста JSON-вкладки редактора узла: три вида входа,
/// тег из поля Tag подмешивается в тело узла (не в корень документа), оба
/// вида секций в одном документе — отказ.
void main() {
  Map<String, dynamic> ready(NodeDocumentPrep p) {
    expect(p, isA<NodeDocumentReady>());
    return jsonDecode((p as NodeDocumentReady).text) as Map<String, dynamic>;
  }

  group('голое тело', () {
    test('объект с type → тег подмешан в корень, isDocument=false', () {
      final p = prepareNodeDocumentForSave(
          '{"type":"socks","tag":"old","server":"h","server_port":1080}',
          'new-tag');
      final m = ready(p);
      expect((p as NodeDocumentReady).isDocument, isFalse);
      expect(m['tag'], 'new-tag');
      expect(m['type'], 'socks');
      expect(m['server'], 'h');
    });

    test('пустой Tag → тег тела не трогается', () {
      final p = prepareNodeDocumentForSave(
          '{"type":"socks","tag":"keep","server":"h","server_port":1080}',
          '   ');
      expect(ready(p)['tag'], 'keep');
    });

    test('массив тел → первый элемент', () {
      final p = prepareNodeDocumentForSave(
          '[{"type":"socks","tag":"a","server":"h","server_port":1},'
          '{"type":"socks","tag":"b","server":"h","server_port":2}]',
          't');
      final m = ready(p);
      expect(m['tag'], 't');
      expect(m['server_port'], 1);
    });

    test('пустой массив → отказ', () {
      expect(prepareNodeDocumentForSave('[]', 't'),
          isA<NodeDocumentRejected>());
    });
  });

  group('документ с sections', () {
    const doc = '{"endpoints":[{"type":"tailscale","tag":"ts",'
        '"auth_key":"tskey-x"}],'
        '"sections":{"rules":[{"kind":"inline","name":"@{self} network",'
        '"enabled":true,"num":945,'
        '"body":{"ip_cidr":["100.64.0.0/10"],"outbound":"@self"}}]}}';

    test('тег — в тело первого endpoint\'а, документ уходит целиком', () {
      final p = prepareNodeDocumentForSave(doc, '🪢 home');
      final m = ready(p);
      expect((p as NodeDocumentReady).isDocument, isTrue);
      expect(m.containsKey('tag'), isFalse, reason: 'тег не в корне');
      final body = (m['endpoints'] as List).single as Map;
      expect(body['tag'], '🪢 home');
      expect(body['auth_key'], 'tskey-x');
      expect(m['sections'], isA<Map>());
      expect(((m['sections'] as Map)['rules'] as List), hasLength(1));
    });

    test('пустой Tag → тег тела не трогается', () {
      final m = ready(prepareNodeDocumentForSave(doc, ''));
      expect(((m['endpoints'] as List).single as Map)['tag'], 'ts');
    });
  });

  group('sing-box-документ с dns/route', () {
    const doc = '{"outbounds":[{"type":"direct","tag":"direct"},'
        '{"type":"socks","tag":"s","server":"h","server_port":1}],'
        '"dns":{"servers":[{"type":"udp","tag":"d","server":"1.1.1.1",'
        '"detour":"s"}]},'
        '"route":{"rules":[{"ip_cidr":["10.0.0.0/8"],"outbound":"s"}]}}';

    test('тег — в первое НЕ служебное тело (direct пропущен)', () {
      final m = ready(prepareNodeDocumentForSave(doc, 'renamed'));
      final obs = m['outbounds'] as List;
      expect((obs[0] as Map)['tag'], 'direct');
      expect((obs[1] as Map)['tag'], 'renamed');
      expect(m['dns'], isA<Map>());
      expect(m['route'], isA<Map>());
    });

    test('endpoints раньше outbounds при выборе тела', () {
      const both = '{"outbounds":[{"type":"socks","tag":"o","server":"h",'
          '"server_port":1}],'
          '"endpoints":[{"type":"wireguard","tag":"e"}],"route":{}}';
      final m = ready(prepareNodeDocumentForSave(both, 'x'));
      expect(((m['endpoints'] as List).single as Map)['tag'], 'x');
      expect(((m['outbounds'] as List).single as Map)['tag'], 'o');
    });

    test('группы не считаются телом узла', () {
      const grp = '{"outbounds":[{"type":"selector","tag":"sel",'
          '"outbounds":["s"]},{"type":"socks","tag":"s","server":"h",'
          '"server_port":1}]}';
      final m = ready(prepareNodeDocumentForSave(grp, 'x'));
      final obs = m['outbounds'] as List;
      expect((obs[0] as Map)['tag'], 'sel');
      expect((obs[1] as Map)['tag'], 'x');
    });
  });

  group('отказы', () {
    test('sections и dns/route в одном документе', () {
      const doc = '{"endpoints":[{"type":"tailscale","tag":"ts"}],'
          '"sections":{"rules":[]},"route":{"rules":[]}}';
      final p = prepareNodeDocumentForSave(doc, 't');
      expect(p, isA<NodeDocumentRejected>());
      expect((p as NodeDocumentRejected).message, contains('sections'));
    });

    test('sections и dns без route — тоже отказ', () {
      const doc = '{"outbounds":[{"type":"socks","tag":"s","server":"h",'
          '"server_port":1}],"sections":{},"dns":{"servers":[]}}';
      expect(prepareNodeDocumentForSave(doc, 't'),
          isA<NodeDocumentRejected>());
    });

    test('битый JSON', () {
      final p = prepareNodeDocumentForSave('{"type": ', 't');
      expect(p, isA<NodeDocumentRejected>());
      expect((p as NodeDocumentRejected).message, contains('Invalid JSON'));
    });

    test('объект без type и без endpoints/outbounds', () {
      expect(prepareNodeDocumentForSave('{"tag":"x"}', 't'),
          isA<NodeDocumentRejected>());
    });

    test('скаляр', () {
      expect(prepareNodeDocumentForSave('42', 't'),
          isA<NodeDocumentRejected>());
    });
  });


  group('§455 checkPayloadFor', () {
    test('голое тело → outbounds без detour', () {
      final payload = checkPayloadFor(
          '{"type":"socks","tag":"a","server":"h","server_port":1080,'
          '"detour":"x","foo":1}');
      final m = jsonDecode(payload!) as Map<String, dynamic>;
      final body = (m['outbounds'] as List).single as Map;
      expect(body['tag'], 'a');
      expect(body.containsKey('detour'), isFalse);
      expect(body['foo'], 1); // ключ вне модели — ядро проверит его само
      expect(m.containsKey('endpoints'), isFalse);
    });

    test('wireguard → endpoints', () {
      final payload = checkPayloadFor(jsonEncode({
        'type': 'wireguard',
        'tag': 'wg',
        'address': ['10.0.0.2/32'],
        'private_key': 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=',
        'peers': [
          {
            'address': '1.2.3.4',
            'port': 51820,
            'public_key': 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=',
            'allowed_ips': ['0.0.0.0/0'],
          }
        ],
      }));
      final m = jsonDecode(payload!) as Map<String, dynamic>;
      expect((m['endpoints'] as List).single['tag'], 'wg');
    });

    test('документ с sections → тело узла', () {
      final payload = checkPayloadFor(jsonEncode({
        'outbounds': [
          {'type': 'socks', 'tag': 'a', 'server': 'h', 'server_port': 1080}
        ],
        'sections': {'rules': []},
      }));
      final m = jsonDecode(payload!) as Map<String, dynamic>;
      expect((m['outbounds'] as List).single['type'], 'socks');
    });

    test('не JSON и не узел → null', () {
      expect(checkPayloadFor('garbage'), isNull);
    });
  });

  group('§455 текст источника сохраняется как набран', () {
    test('тег не менялся → исходный текст байт в байт', () {
      const text = '{ "type": "socks",\n  "tag": "keep", "server": "h", "server_port": 1 }';
      final p = prepareNodeDocumentForSave(text, 'keep') as NodeDocumentReady;
      expect(p.text, text);
      final q = prepareNodeDocumentForSave(text, '') as NodeDocumentReady;
      expect(q.text, text);
    });
  });
}
