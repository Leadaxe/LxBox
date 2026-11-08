import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/source_dialect.dart';
import 'package:lxbox/screens/node_settings/node_document.dart';
import 'package:lxbox/services/parser/source_classify.dart';

import '../../parser/engine_test_setup.dart';

/// §435 / §722 — подготовка текста вкладки Source редактора узла. Источник
/// хранится в своём диалекте (контракт 1.1.165, PARSING_PRINCIPLES §11): голое
/// тело как набрано, документ — целиком, обрезанный до узловых массивов,
/// массив — первый элемент; вид записи — результат классификации входа.
void main() {
  setUpAll(loadEngineSections);

  NodeDocumentReady readyOf(NodeDocumentPrep p) {
    expect(p, isA<NodeDocumentReady>(),
        reason: p is NodeDocumentRejected ? p.message : '');
    return p as NodeDocumentReady;
  }

  Map<String, dynamic> ready(NodeDocumentPrep p) =>
      jsonDecode(readyOf(p).text) as Map<String, dynamic>;

  // #209 — Xray-узел: outbound и конфиг с цепочкой `dialerProxy`.
  const xrayOut = '{"tag":"xr","protocol":"vless","settings":{"vnext":'
      '[{"address":"example-1.com","port":443,"users":[{"id":'
      '"11111111-2222-3333-4444-555555555555","encryption":"none"}]}]},'
      '"streamSettings":{"network":"tcp","security":"none"}}';
  final xrayChain = jsonEncode({
    'log': {'loglevel': 'warning'},
    'outbounds': [
      {
        'tag': 'main',
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': 'example-1.com',
              'port': 443,
              'users': [
                {'id': '11111111-2222-3333-4444-555555555555', 'encryption': 'none'}
              ],
            }
          ],
        },
        'streamSettings': {
          'network': 'tcp',
          'security': 'none',
          'sockopt': {'dialerProxy': 'relay'},
        },
      },
      {
        'tag': 'relay',
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': 'example-2.com',
              'port': 443,
              'users': [
                {'id': '11111111-2222-3333-4444-555555555556', 'encryption': 'none'}
              ],
            }
          ],
        },
        'streamSettings': {'network': 'tcp', 'security': 'none'},
      },
      {'tag': 'direct', 'protocol': 'freedom'},
    ],
    'routing': {
      'rules': [
        {'type': 'field', 'outboundTag': 'main', 'network': 'tcp,udp'}
      ],
    },
  });

  group('голое тело sing-box', () {
    test('объект с type → тег подмешан в корень, вид singbox', () {
      final p = readyOf(prepareNodeDocumentForSave(
          '{"type":"socks","tag":"old","server":"h","server_port":1080}',
          'new-tag'));
      final m = jsonDecode(p.text) as Map<String, dynamic>;
      expect(p.dialect, SourceDialect.singbox);
      expect(p.isDocument, isFalse);
      expect(p.droppedExtras, isFalse);
      expect(m['tag'], 'new-tag');
      expect(m['type'], 'socks');
    });

    test('пустой Tag → тег тела не трогается', () {
      final p = prepareNodeDocumentForSave(
          '{"type":"socks","tag":"keep","server":"h","server_port":1080}',
          '   ');
      expect(ready(p)['tag'], 'keep');
    });

    test('тег не менялся → исходный текст байт в байт', () {
      const text =
          '{ "type": "socks",\n  "tag": "keep", "server": "h", "server_port": 1 }';
      expect(readyOf(prepareNodeDocumentForSave(text, 'keep')).text, text);
      expect(readyOf(prepareNodeDocumentForSave(text, '')).text, text);
    });
  });

  group('§722 Xray (#209)', () {
    test('outbound: смена тега → Ready, текст Xray, вид xray', () {
      final p = readyOf(prepareNodeDocumentForSave(xrayOut, 'renamed'));
      expect(p.dialect, SourceDialect.xray);
      final m = jsonDecode(p.text) as Map<String, dynamic>;
      expect(m['protocol'], 'vless');
      expect(m['tag'], 'renamed');
      expect(m.containsKey('type'), isFalse);
      expect(p.droppedExtras, isFalse);
    });

    test('конфиг с dialerProxy → целиком, routing/log сняты, остаток назван',
        () {
      final p = readyOf(prepareNodeDocumentForSave(xrayChain, ''));
      expect(p.dialect, SourceDialect.xray);
      expect(p.isDocument, isTrue);
      expect(p.droppedExtras, isTrue);
      final m = jsonDecode(p.text) as Map<String, dynamic>;
      expect(m.keys, ['outbounds']);
      expect((m['outbounds'] as List), hasLength(3));
    });

    test('переименование владельца переписывает dialerProxy звена', () {
      final p = readyOf(prepareNodeDocumentForSave(
          xrayChain, 'relay-new', oldTag: 'relay'));
      final obs = (ready(p)['outbounds'] as List).cast<Map>();
      expect(obs[1]['tag'], 'relay-new');
      expect(
          ((obs[0]['streamSettings'] as Map)['sockopt'] as Map)['dialerProxy'],
          'relay-new');
    });

    test('без oldTag переименовывается владелец, не звено', () {
      final obs = (ready(prepareNodeDocumentForSave(xrayChain, 'owner'))[
              'outbounds'] as List)
          .cast<Map>();
      expect(obs[0]['tag'], 'owner');
      expect(obs[1]['tag'], 'relay');
    });

    test('вставка sing-box в Xray-запись → вид singbox (вид меняется)', () {
      final p = readyOf(prepareNodeDocumentForSave(
          '{"type":"trojan","server":"example-1.com","server_port":443,'
              '"password":"p"}',
          ''));
      expect(p.dialect, SourceDialect.singbox);
    });
  });

  group('документ sing-box', () {
    test('outbounds/endpoints оставлены, route/dns/sections сняты', () {
      const doc = '{"endpoints":[{"type":"wireguard","tag":"e"}],'
          '"outbounds":[{"type":"socks","tag":"s","server":"h",'
          '"server_port":1}],'
          '"dns":{"servers":[]},"route":{"rules":[]},"sections":{}}';
      final c = classifySource(doc);
      expect(c.dialect, SourceDialect.singbox);
      final item = c.items.single;
      expect(item.extrasDropped, isTrue);
      final m = jsonDecode(item.text) as Map<String, dynamic>;
      expect(m.keys.toSet(), {'endpoints', 'outbounds'});
    });

    test('несколько узлов — хранится целиком, без сообщения', () {
      const doc = '{"outbounds":[{"type":"direct","tag":"direct"},'
          '{"type":"socks","tag":"s","server":"h","server_port":1},'
          '{"type":"socks","tag":"s2","server":"h","server_port":2}]}';
      final p = readyOf(prepareNodeDocumentForSave(doc, ''));
      expect(p.text, doc);
      expect(p.isDocument, isTrue);
      expect(p.droppedExtras, isFalse);
    });

    test('переименование: первый узел, ссылки detour переписаны', () {
      const doc = '{"outbounds":[{"type":"direct","tag":"direct"},'
          '{"type":"socks","tag":"s","server":"h","server_port":1,'
          '"detour":"hop"},'
          '{"type":"socks","tag":"hop","server":"h","server_port":2}]}';
      final obs = (ready(prepareNodeDocumentForSave(doc, 'hop2',
              oldTag: 'hop'))['outbounds'] as List)
          .cast<Map>();
      expect(obs[2]['tag'], 'hop2');
      expect(obs[1]['detour'], 'hop2');
      final own = (ready(prepareNodeDocumentForSave(doc, 'main'))['outbounds']
              as List)
          .cast<Map>();
      expect(own[1]['tag'], 'main');
      expect(own[2]['tag'], 'hop');
    });

    test('подходящего узла нет → отказ', () {
      const doc = '{"outbounds":[{"type":"direct","tag":"direct"},'
          '{"type":"selector","tag":"sel","outbounds":["direct"]}]}';
      expect(prepareNodeDocumentForSave(doc, 't'),
          isA<NodeDocumentRejected>());
    });
  });

  group('массив — форма ввода', () {
    test('классификация режет массив на элементы', () {
      final c = classifySource(
          '[{"type":"socks","tag":"a","server":"h","server_port":1},'
          '{"type":"socks","tag":"b","server":"h","server_port":2},'
          '{"type":"socks","tag":"c","server":"h","server_port":3}]');
      expect(c.wasArray, isTrue);
      expect(c.items, hasLength(3));
      expect(c.items.every((i) => i.dialect == SourceDialect.singbox), isTrue);
    });

    test('Save: первый элемент, остальное не сохранено', () {
      final p = readyOf(prepareNodeDocumentForSave(
          '[{"type":"socks","tag":"a","server":"h","server_port":1},'
          '{"type":"socks","tag":"b","server":"h","server_port":2}]',
          't'));
      final m = jsonDecode(p.text) as Map<String, dynamic>;
      expect(m['tag'], 't');
      expect(m['server_port'], 1);
      expect(p.droppedExtras, isTrue);
      expect(p.text, contains('\n  "type"'), reason: 'отступ два пробела');
    });

    test('один элемент — сообщения нет', () {
      final p = readyOf(prepareNodeDocumentForSave(
          '[{"type":"socks","tag":"a","server":"h","server_port":1}]', ''));
      expect((jsonDecode(p.text) as Map)['tag'], 'a');
      expect(p.droppedExtras, isFalse);
    });

    test('пустой массив → отказ', () {
      expect(prepareNodeDocumentForSave('[]', 't'),
          isA<NodeDocumentRejected>());
    });
  });

  group('ссылка и INI', () {
    test('ссылка → вид uri, тег во фрагмент', () {
      final p = readyOf(prepareNodeDocumentForSave('trojan://p@h:443#t', 'n'));
      expect(p.dialect, SourceDialect.uri);
      expect(p.text, 'trojan://p@h:443#n');
    });

    test('INI → вид wg_ini, текст как есть, тег — nameHint', () {
      const ini = '[Interface]\nPrivateKey = '
          'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=\n'
          'Address = 10.0.0.2/32\n\n[Peer]\nPublicKey = '
          'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=\n'
          'Endpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0';
      final p = readyOf(prepareNodeDocumentForSave(ini, 'home'));
      expect(p.dialect, SourceDialect.wgIni);
      expect(p.text, ini);
      expect(p.nameHint, 'home');
    });
  });

  group('отказы', () {
    test('битый JSON', () {
      final p = prepareNodeDocumentForSave('{"type": ', 't');
      expect(p, isA<NodeDocumentRejected>());
      expect((p as NodeDocumentRejected).message, contains('Invalid JSON'));
    });

    test('объект без вида (ни sing-box, ни Xray)', () {
      expect(prepareNodeDocumentForSave('{"tag":"x"}', 't'),
          isA<NodeDocumentRejected>());
    });
  });

  group('§455 checkPayloadFor', () {
    test('голое тело singbox → outbounds дословно', () {
      final payload = checkPayloadFor(
          '{"type":"socks","tag":"a","server":"h","server_port":1080,'
          '"foo":1}',
          SourceDialect.singbox);
      final m = jsonDecode(payload!) as Map<String, dynamic>;
      final body = (m['outbounds'] as List).single as Map;
      expect(body['tag'], 'a');
      expect(body.containsKey('detour'), isFalse);
      expect(body['foo'], 1); // ключ вне модели — ядро проверит его само
      expect(m.containsKey('endpoints'), isFalse);
    });

    // §642 (контракт 1.1.118, D-128) — голое тело с `detour` на чужой тег:
    // хоп без узла = `detour_target_missing`, узла нет, проверять нечего.
    test('голое тело с висячим detour → null', () {
      expect(
          checkPayloadFor(
              '{"type":"socks","tag":"a","server":"h","server_port":1080,'
              '"detour":"x"}',
              SourceDialect.singbox),
          isNull);
    });

    test('wireguard → endpoints', () {
      final payload = checkPayloadFor(
          jsonEncode({
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
          }),
          SourceDialect.singbox);
      final m = jsonDecode(payload!) as Map<String, dynamic>;
      expect((m['endpoints'] as List).single['tag'], 'wg');
    });

    // §722 — Xray-документ с цепочкой: в проверку идут ВСЕ узлы записи
    // (владелец и звено), телами модели — не null.
    test('Xray-документ с dialerProxy → оба узла, форма sing-box', () {
      final doc = readyOf(prepareNodeDocumentForSave(xrayChain, '')).text;
      final payload = checkPayloadFor(doc, SourceDialect.xray);
      final m = jsonDecode(payload!) as Map<String, dynamic>;
      final obs = (m['outbounds'] as List).cast<Map>();
      expect(obs.length, greaterThanOrEqualTo(2));
      expect(obs.every((o) => o['type'] == 'vless'), isTrue);
      final servers = {for (final o in obs) o['server']};
      expect(servers, containsAll(['example-1.com', 'example-2.com']));
      expect(obs.any((o) => o.containsKey('protocol')), isFalse);
    });

    test('не JSON и не узел → null', () {
      expect(checkPayloadFor('garbage', SourceDialect.uri), isNull);
    });
  });
}
