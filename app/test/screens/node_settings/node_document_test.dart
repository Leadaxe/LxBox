import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/node_settings/node_document.dart';

/// §435 — подготовка текста JSON-вкладки редактора узла. §576 — в источник
/// уходит только тело узла: голое тело как набрано, из документа — первый
/// узел (не служебный и не группа), из массива — первый элемент; об остатке
/// флаг `droppedExtras` для одного сообщения.
void main() {
  Map<String, dynamic> ready(NodeDocumentPrep p) {
    expect(p, isA<NodeDocumentReady>());
    return jsonDecode((p as NodeDocumentReady).text) as Map<String, dynamic>;
  }

  // §576 п.1 — строки таблицы: голое тело, документ, массив здесь; ссылка и
  // INI через эту функцию не идут (экран решает по первому символу и пишет
  // их как раньше), группа `ссылка и INI` ниже фиксирует это.
  group('голое тело', () {
    test('объект с type → тег подмешан в корень, isDocument=false', () {
      final p = prepareNodeDocumentForSave(
          '{"type":"socks","tag":"old","server":"h","server_port":1080}',
          'new-tag');
      final m = ready(p);
      expect((p as NodeDocumentReady).isDocument, isFalse);
      expect(p.droppedExtras, isFalse);
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
  });

  group('массив тел', () {
    test('первый элемент, остальное не сохранено', () {
      final p = prepareNodeDocumentForSave(
          '[{"type":"socks","tag":"a","server":"h","server_port":1},'
          '{"type":"socks","tag":"b","server":"h","server_port":2}]',
          't');
      final m = ready(p);
      expect(m['tag'], 't');
      expect(m['server_port'], 1);
      expect(m.containsKey('outbounds'), isFalse);
      expect((p as NodeDocumentReady).droppedExtras, isTrue);
      expect(p.text, contains('\n  "type"'), reason: 'отступ два пробела');
    });

    test('один элемент — сообщения нет', () {
      final p = prepareNodeDocumentForSave(
          '[{"type":"socks","tag":"a","server":"h","server_port":1}]', '');
      expect(ready(p)['tag'], 'a');
      expect((p as NodeDocumentReady).droppedExtras, isFalse);
    });

    test('пустой массив → отказ', () {
      expect(prepareNodeDocumentForSave('[]', 't'),
          isA<NodeDocumentRejected>());
    });
  });

  group('документ', () {
    test('с sections → тело endpoint\'а, остальное не сохранено', () {
      const doc = '{"endpoints":[{"type":"tailscale","tag":"ts",'
          '"auth_key":"tskey-x"}],'
          '"sections":{"rules":[{"kind":"inline","name":"@{self} network",'
          '"enabled":true,"num":945,'
          '"body":{"ip_cidr":["100.64.0.0/10"],"outbound":"@self"}}]}}';
      final p = prepareNodeDocumentForSave(doc, '🪢 home');
      final m = ready(p);
      expect((p as NodeDocumentReady).isDocument, isTrue);
      expect(p.droppedExtras, isTrue);
      expect(m['type'], 'tailscale');
      expect(m['tag'], '🪢 home');
      expect(m['auth_key'], 'tskey-x');
      expect(m.containsKey('sections'), isFalse);
      expect(m.containsKey('endpoints'), isFalse);
    });

    test('служебные и группы пропускаются, берётся первый узел', () {
      const doc = '{"outbounds":[{"type":"direct","tag":"direct"},'
          '{"type":"selector","tag":"sel","outbounds":["s","s2"]},'
          '{"type":"socks","tag":"s","server":"h","server_port":1},'
          '{"type":"socks","tag":"s2","server":"h","server_port":2}],'
          '"dns":{"servers":[]},"route":{"rules":[]}}';
      final p = prepareNodeDocumentForSave(doc, 'renamed');
      final m = ready(p);
      expect(m['server_port'], 1);
      expect(m['tag'], 'renamed');
      expect(m.containsKey('dns'), isFalse);
      expect((p as NodeDocumentReady).droppedExtras, isTrue);
    });

    test('endpoints раньше outbounds при выборе тела', () {
      const both = '{"outbounds":[{"type":"socks","tag":"o","server":"h",'
          '"server_port":1}],'
          '"endpoints":[{"type":"wireguard","tag":"e"}]}';
      final m = ready(prepareNodeDocumentForSave(both, 'x'));
      expect(m['type'], 'wireguard');
      expect(m['tag'], 'x');
    });

    test('документ из одного узла — сообщения нет, пустой Tag не трогает тег',
        () {
      const doc = '{"outbounds":[{"type":"socks","tag":"s","server":"h",'
          '"server_port":1}]}';
      final p = prepareNodeDocumentForSave(doc, '');
      expect(ready(p)['tag'], 's');
      expect((p as NodeDocumentReady).droppedExtras, isFalse);
    });

    test('подходящего узла нет → отказ', () {
      const doc = '{"outbounds":[{"type":"direct","tag":"direct"},'
          '{"type":"selector","tag":"sel","outbounds":["direct"]}]}';
      expect(prepareNodeDocumentForSave(doc, 't'),
          isA<NodeDocumentRejected>());
    });
  });

  group('ссылка и INI', () {
    test('не JSON — отказ этой функции, экран пишет их своей веткой', () {
      expect(prepareNodeDocumentForSave('trojan://p@h:443#t', 't'),
          isA<NodeDocumentRejected>());
      expect(
          prepareNodeDocumentForSave(
              '[Interface]\nPrivateKey = x\n\n[Peer]\nEndpoint = h:1\n', 't'),
          isA<NodeDocumentRejected>());
    });
  });

  group('отказы', () {
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
