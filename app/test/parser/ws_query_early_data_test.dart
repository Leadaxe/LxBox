import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/transport_spec.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/transport.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §320 — вторая форма WebSocket early data: плоские `ed`/`eh` в query, а не
/// хвостом пути (§303). Потеря `eh` ломает коннект: при пустом
/// `early_data_header_name` ядро дописывает base64 В ПУТЬ (conn.go:172), а
/// сервер с `eh=Sec-WebSocket-Protocol` ждёт данные в заголовке → 404.
void main() {
  Map<String, dynamic> wsMap(TransportSpec? t) =>
      t!.toSingbox(const TemplateVars()).$1;

  group('ed/eh плоскими query-параметрами', () {
    test('ed+eh → max_early_data + early_data_header_name', () {
      final t = parseTransport({
        'type': 'ws',
        'path': '/',
        'ed': '2560',
        'eh': 'Sec-WebSocket-Protocol',
      });
      expect(wsMap(t), {
        'type': 'ws',
        'path': '/',
        'max_early_data': 2560,
        'early_data_header_name': 'Sec-WebSocket-Protocol',
      });
    });

    test('только ed → path-режим (имя заголовка не подставляем, §303)', () {
      final t = parseTransport({'type': 'ws', 'path': '/x', 'ed': '2048'});
      final m = wsMap(t);
      expect(m['max_early_data'], 2048);
      expect(m.containsKey('early_data_header_name'), isFalse);
    });

    test('eh без ed игнорируется целиком', () {
      final t = parseTransport({
        'type': 'ws',
        'path': '/x',
        'eh': 'Sec-WebSocket-Protocol',
      });
      final m = wsMap(t);
      expect(m.containsKey('max_early_data'), isFalse);
      expect(m.containsKey('early_data_header_name'), isFalse);
    });

    test('хвост пути в приоритете над плоским ed', () {
      final t = parseTransport({
        'type': 'ws',
        'path': '/x?ed=1024',
        'ed': '2560',
        'eh': 'Sec-WebSocket-Protocol',
      });
      final m = wsMap(t);
      expect(m['path'], '/x');
      expect(m['max_early_data'], 1024);
      // eh парой с ed из пути всё равно применяется — режим задаёт провайдер.
      expect(m['early_data_header_name'], 'Sec-WebSocket-Protocol');
    });

    test('битый/неположительный ed → ни одного ключа', () {
      for (final bad in ['abc', '-1', '0', '']) {
        final m = wsMap(parseTransport({
          'type': 'ws',
          'path': '/x',
          'ed': bad,
          'eh': 'Sec-WebSocket-Protocol',
        }));
        expect(m.containsKey('max_early_data'), isFalse, reason: 'ed=$bad');
        expect(m.containsKey('early_data_header_name'), isFalse,
            reason: 'ed=$bad');
      }
    });

    test('пустой eh не эмитится', () {
      final m = wsMap(
          parseTransport({'type': 'ws', 'path': '/x', 'ed': '100', 'eh': '  '}));
      expect(m['max_early_data'], 100);
      expect(m.containsKey('early_data_header_name'), isFalse);
    });

    test('httpupgrade: ed/eh из query не читаются', () {
      final m = wsMap(parseTransport({
        'type': 'httpupgrade',
        'path': '/x',
        'ed': '2560',
        'eh': 'Sec-WebSocket-Protocol',
      }));
      expect(m, {'type': 'httpupgrade', 'path': '/x'});
    });
  });

  group('реальный узел подписки', () {
    test('trojan с ed/eh в query → оба поля в конфиге', () {
      final n = parseUri(
        'trojan://Aimer@167.68.4.199:2053?ed=2560'
        '&eh=Sec-WebSocket-Protocol&host=epge.muarua.filegear-sg.me'
        '&path=%2F&sni=epge.muarua.filegear-sg.me&type=ws#node',
      )!;
      final tr = n.emitRaw(const TemplateVars()).map['transport'] as Map;
      expect(tr['max_early_data'], 2560);
      expect(tr['early_data_header_name'], 'Sec-WebSocket-Protocol');
    });
  });

  group('Xray JSON wsSettings.ed/.eh', () {
    TransportSpec? fromXray(Map<String, dynamic> ws) {
      final specs = parseXrayElement({
        'outbounds': [
          {
            'protocol': 'vless',
            'tag': 'proxy',
            'settings': {
              'vnext': [
                {
                  'address': 'example.com',
                  'port': 443,
                  'users': [
                    {'id': '11111111-2222-3333-4444-555555555555'}
                  ],
                }
              ],
            },
            'streamSettings': {
              'network': 'ws',
              'security': 'tls',
              'wsSettings': ws,
            },
          }
        ],
      });
      return (specs.first as VlessSpec).transport;
    }

    test('ed/eh полями объекта', () {
      final m = wsMap(fromXray({
        'path': '/x',
        'ed': 2560,
        'eh': 'Sec-WebSocket-Protocol',
      }));
      expect(m['max_early_data'], 2560);
      expect(m['early_data_header_name'], 'Sec-WebSocket-Protocol');
    });

    test('ed строкой (нестрогие генераторы)', () {
      final m = wsMap(fromXray({'path': '/x', 'ed': '1500'}));
      expect(m['max_early_data'], 1500);
    });

    test('eh без ed игнорируется', () {
      final m = wsMap(fromXray({'path': '/x', 'eh': 'X-Early'}));
      expect(m.containsKey('max_early_data'), isFalse);
      expect(m.containsKey('early_data_header_name'), isFalse);
    });

    test('хвост пути в приоритете', () {
      final m = wsMap(fromXray({'path': '/x?ed=700', 'ed': 2560}));
      expect(m['path'], '/x');
      expect(m['max_early_data'], 700);
    });
  });

  group('round-trip', () {
    test('toUri несёт и path?ed=, и eh=', () {
      final src = 'trojan://pw@example.com:443?type=ws&path=%2Fx'
          '&ed=2560&eh=Sec-WebSocket-Protocol&security=tls&sni=example.com#n';
      final uri = parseUri(src)!.toUri();
      final q = Uri.parse(uri).queryParameters;
      expect(q['path'], '/x?ed=2560');
      expect(q['eh'], 'Sec-WebSocket-Protocol');

      // Второй проход не теряет ни размер, ни режим.
      final tr = parseUri(uri)!.emitRaw(const TemplateVars()).map['transport']
          as Map;
      expect(tr['path'], '/x');
      expect(tr['max_early_data'], 2560);
      expect(tr['early_data_header_name'], 'Sec-WebSocket-Protocol');
    });

    test('path-режим: eh в ссылку не добавляется', () {
      final uri = parseUri(
        'trojan://pw@example.com:443?type=ws&path=%2Fx%3Fed%3D2560'
        '&security=tls&sni=example.com#n',
      )!
          .toUri();
      final q = Uri.parse(uri).queryParameters;
      expect(q['path'], '/x?ed=2560');
      expect(q.containsKey('eh'), isFalse);
    });
  });
}
