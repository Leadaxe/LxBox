import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/transport_spec.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/transport.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import 'engine_test_setup.dart';

/// §303 — WebSocket early data. Xray задаёт её хвостом пути (`/x?ed=2560`),
/// sing-box — полем `max_early_data`. Раньше хвост уезжал в `transport.path`
/// дословно и сервер отвечал 404.

/// §480 W8 — ссылка узла-носителя с транспортом [t]: её собирает движок по
/// той же секции `uri`, что ведёт разбор. Своей ссылки у транспорта не
/// бывает — он всегда едет параметрами узла.
String _uriOf(TransportSpec t) => VlessSpec(
      id: 'id-1',
      tag: 'n',
      label: 'n',
      server: '1.2.3.4',
      port: 443,
      rawSource: '',
      uuid: 'u-1',
      transport: t,
    ).toUri();

/// Транспорт, доехавший до ссылки и обратно.
WsTransport _viaUri(TransportSpec t) =>
    (parseUri(_uriOf(t)) as VlessSpec).transport! as WsTransport;

void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

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
    // §480 W8 — круг идёт НАСТОЯЩИМ путём: ссылку узла собирает движок по
    // секции `uri`, он же её разбирает. Прежде тесты звали `transportToQuery`
    // — рукописную эмиссию, снятую волной W7.
    //
    // Вид ссылки волна сменила намеренно: `ed` уезжает ОТДЕЛЬНЫМ параметром
    // (`?ed=2560&path=…`), а не хвостом внутри `path`. Обе формы разбор
    // читает — хвост приходит из чужих клиентов и остаётся понятным, — но
    // пишем мы теперь ту, что объявлена записью реестра. Проверяется
    // сохранность смысла: размер early data и путь без хвоста.
    test('ссылка узла возвращает ed отдельным параметром', () {
      final uri = _uriOf(
          const WsTransport(path: '/api/v2/channel', maxEarlyData: 2560));
      expect(Uri.parse(uri).queryParameters['ed'], '2560');
      expect(Uri.parse(uri).queryParameters['path'], '/api/v2/channel');

      final back = _viaUri(
          const WsTransport(path: '/api/v2/channel', maxEarlyData: 2560));
      expect(back.path, '/api/v2/channel');
      expect(back.maxEarlyData, 2560);
    });

    test('без early data path остаётся прежним', () {
      expect(Uri.parse(_uriOf(const WsTransport(path: '/x')))
          .queryParameters['path'],
          '/x');
      expect(_viaUri(const WsTransport(path: '/x')).maxEarlyData, isNull);
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
