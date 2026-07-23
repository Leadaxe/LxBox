import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/transport_spec.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/transport.dart';

/// §303 — WebSocket early data. Xray задаёт её хвостом пути (`/x?ed=2560`),
/// sing-box — полем `max_early_data`. Раньше хвост уезжал в `transport.path`
/// дословно и сервер отвечал 404.
void main() {
  group('splitEarlyDataPath', () {
    test('путь с ed → разделён', () {
      expect(splitEarlyDataPath('/api/v2/channel?ed=2560'),
          ('/api/v2/channel', 2560));
    });

    test('путь без хвоста не меняется', () {
      expect(splitEarlyDataPath('/api/v2/channel'), ('/api/v2/channel', null));
    });

    test('нечисловой / неположительный ed отбрасывается, хвост срезан', () {
      expect(splitEarlyDataPath('/x?ed=abc'), ('/x', null));
      expect(splitEarlyDataPath('/x?ed=-1'), ('/x', null));
      expect(splitEarlyDataPath('/x?ed=0'), ('/x', null));
    });

    test('чужой query-параметр: хвост срезан, ed нет', () {
      expect(splitEarlyDataPath('/x?foo=1'), ('/x', null));
    });

    test('битый percent-encoding не роняет разбор', () {
      expect(splitEarlyDataPath('/x?%zz'), ('/x', null));
    });

    test('пустой путь до `?` → корень', () {
      expect(splitEarlyDataPath('?ed=2048'), ('/', 2048));
    });
  });

  group('URI-транспорт', () {
    test('type=ws + path с ed → path чистый, maxEarlyData заполнен', () {
      final t = parseTransport({
        'type': 'ws',
        'path': '/api/v2/channel?ed=2560',
        'host': 'example.com',
      }) as WsTransport;
      expect(t.path, '/api/v2/channel');
      expect(t.maxEarlyData, 2560);
      expect(t.host, 'example.com');
    });

    test('httpupgrade: хвост срезан, early data не появляется', () {
      final t = parseTransport({
        'type': 'httpupgrade',
        'path': '/up?ed=2048',
      }) as HttpUpgradeTransport;
      expect(t.path, '/up');
      final (m, _) = t.toSingbox(TemplateVars.empty);
      expect(m.containsKey('max_early_data'), isFalse);
      expect(m['path'], '/up');
    });
  });

  group('emit → sing-box', () {
    test('maxEarlyData эмитится ключом max_early_data', () {
      final (m, w) = const WsTransport(
        path: '/api/v2/channel',
        maxEarlyData: 2560,
      ).toSingbox(TemplateVars.empty);
      expect(m['type'], 'ws');
      expect(m['path'], '/api/v2/channel');
      expect(m['max_early_data'], 2560);
      // Пустой header name = path-режим (как у Xray `ed`) — ключ не эмитим.
      expect(m.containsKey('early_data_header_name'), isFalse);
      expect(w, isEmpty);
    });

    test('без early data лишних ключей нет', () {
      final (m, _) =
          const WsTransport(path: '/x').toSingbox(TemplateVars.empty);
      expect(m.containsKey('max_early_data'), isFalse);
      expect(m.containsKey('early_data_header_name'), isFalse);
    });

    test('заданный header name переключает на header-режим', () {
      final (m, _) = const WsTransport(
        path: '/x',
        maxEarlyData: 2048,
        earlyDataHeaderName: 'Sec-WebSocket-Protocol',
      ).toSingbox(TemplateVars.empty);
      expect(m['max_early_data'], 2048);
      expect(m['early_data_header_name'], 'Sec-WebSocket-Protocol');
    });
  });

  group('round-trip URI', () {
    test('transportToQuery возвращает ed в хвост пути', () {
      final q = transportToQuery(
          const WsTransport(path: '/api/v2/channel', maxEarlyData: 2560));
      expect(q['path'], '/api/v2/channel?ed=2560');

      final back = parseTransport({'type': 'ws', ...q}) as WsTransport;
      expect(back.path, '/api/v2/channel');
      expect(back.maxEarlyData, 2560);
    });

    test('без early data path остаётся прежним', () {
      final q = transportToQuery(const WsTransport(path: '/x'));
      expect(q['path'], '/x');
    });
  });

  group('JSON-импорт', () {
    test('Xray wsSettings.path с ed → разделён', () {
      final spec = parseXrayOutbound({
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
              ]
            },
            'streamSettings': {
              'network': 'ws',
              'security': 'tls',
              'wsSettings': {
                'path': '/api/v2/channel?ed=2560',
                'headers': {'Host': 'example.com'},
              },
            },
          }
        ]
      });
      final t = (spec as VlessSpec).transport as WsTransport;
      expect(t.path, '/api/v2/channel');
      expect(t.maxEarlyData, 2560);
      expect(t.host, 'example.com');
    });

    test('sing-box entry: max_early_data полем + чистый path', () {
      final spec = parseSingboxEntry({
        'type': 'vless',
        'tag': 'n1',
        'server': 'example.com',
        'server_port': 443,
        'uuid': '11111111-2222-3333-4444-555555555555',
        'transport': {
          'type': 'ws',
          'path': '/api/v2/channel',
          'max_early_data': 2560,
          'early_data_header_name': 'Sec-WebSocket-Protocol',
        },
      });
      final t = (spec as VlessSpec).transport as WsTransport;
      expect(t.path, '/api/v2/channel');
      expect(t.maxEarlyData, 2560);
      expect(t.earlyDataHeaderName, 'Sec-WebSocket-Protocol');
    });

    test('sing-box entry со склеенным Xray-путём тоже чинится', () {
      final spec = parseSingboxEntry({
        'type': 'vless',
        'tag': 'n2',
        'server': 'example.com',
        'server_port': 443,
        'uuid': '11111111-2222-3333-4444-555555555555',
        'transport': {'type': 'ws', 'path': '/api/v2/channel?ed=2560'},
      });
      final t = (spec as VlessSpec).transport as WsTransport;
      expect(t.path, '/api/v2/channel');
      expect(t.maxEarlyData, 2560);
    });
  });
}
