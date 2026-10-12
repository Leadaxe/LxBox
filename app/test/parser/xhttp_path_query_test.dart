import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/transport_spec.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/singbox_config.dart';
import 'package:lxbox/services/parser/transport.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import 'engine_test_setup.dart';

/// §620 — `path` у XHTTP несёт query: всё после первого `?` — query запроса
/// (контракт Xray, `splithttp/config.go`; ядро — sing-box-lx SPEC 119).
/// Релей Cloudflare Worker (sing-box-lx#36) читает `proxyip` именно оттуда:
/// срезанный хвост оставлял узел без выхода к сайтам за Cloudflare.
///
/// У ws хвост `?ed=N` — early data, и он по-прежнему срезается (§303).

const _relayPath = '/?proxyip=149.56.109.62';

/// Узел-носитель с транспортом [t] — ссылку собирает движок по секции `uri`.
VlessSpec _node(TransportSpec t) => VlessSpec(
      id: 'id-1',
      tag: 'n',
      label: 'n',
      server: '1.2.3.4',
      port: 443,
      rawSource: '',
      uuid: 'u-1',
      transport: t,
    );

/// Xray-элемент с одним VLESS-узлом на XHTTP.
Map<String, dynamic> _xrayElement(Map<String, dynamic> xhttpSettings) => {
      'remarks': 'x',
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {
                'address': '1.2.3.4',
                'port': 443,
                'users': [
                  {'id': 'u-1', 'encryption': 'none'}
                ],
              }
            ],
          },
          'streamSettings': {
            'network': 'xhttp',
            'security': 'none',
            'xhttpSettings': xhttpSettings,
          },
        },
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
    };

/// sing-box outbound VLESS с транспортом [transport].
Map<String, dynamic> _singboxOutbound(
        String tag, Map<String, dynamic> transport) =>
    {
      'type': 'vless',
      'tag': tag,
      'server': '1.2.3.4',
      'server_port': 443,
      'uuid': '11111111-2222-3333-4444-555555555555',
      'transport': transport,
    };

void main() {
  setUpAll(loadEngineSections);

  group('xhttpFromMap — общий код трёх веток', () {
    test('URI-карта: percent-кодированный path с query → дословно', () {
      // `Uri.queryParameters` снимает один слой кодирования — как в разборе
      // ссылки.
      final q = Uri.parse('x://h?type=xhttp&path=%2F%3Fproxyip%3D149.56.109.62')
          .queryParameters;
      final warnings = <NodeWarning>[];
      final t = parseTransport(q, warnings: warnings) as XhttpTransport;
      expect(t.path, _relayPath);
      // `?`, `=`, `&` — не percent-последовательности, кода нет.
      expect(warnings, isEmpty);
    });

    test('URI-карта: /base?x=1 → дословно', () {
      final t = parseTransport({'type': 'xhttp', 'path': '/base?x=1&y=2'})
          as XhttpTransport;
      expect(t.path, '/base?x=1&y=2');
    });

    test('путь без ? не меняется', () {
      final t =
          parseTransport({'type': 'xhttp', 'path': '/xhttp'}) as XhttpTransport;
      expect(t.path, '/xhttp');
    });

    test('без ключа path путь не задан, явный пустой — корень', () {
      expect((parseTransport({'type': 'xhttp'}) as XhttpTransport).path, '');
      expect(
          (parseTransport({'type': 'xhttp', 'path': ''}) as XhttpTransport)
              .path,
          '/');
    });

    test('Xray-JSON-карта: xhttpSettings.path с query → дословно', () {
      final t = xhttpFromMap(
          xhttpScalarsFromJson({'path': _relayPath, 'mode': 'stream-one'}));
      expect(t.path, _relayPath);
      expect(t.mode, 'stream-one');
    });
  });

  group('ws/httpupgrade — хвост по-прежнему срезается', () {
    test('ws: ?ed=N → путь чистый, early data заполнена', () {
      final t = parseTransport({'type': 'ws', 'path': '/x?ed=2048'})
          as WsTransport;
      expect(t.path, '/x');
      expect(t.maxEarlyData, 2048);
    });

    test('ws через ссылку: хвост в percent-кодированном path срезан', () {
      final n = parseUri('vless://u-1@1.2.3.4:443?type=ws&security=none'
          '&path=%2Fx%3Fed%3D2048#n') as VlessSpec;
      final t = n.transport! as WsTransport;
      expect(t.path, '/x');
      expect(t.maxEarlyData, 2048);
    });

    test('httpupgrade: чужой query срезан', () {
      final t = parseTransport({'type': 'httpupgrade', 'path': '/up?foo=1'})
          as HttpUpgradeTransport;
      expect(t.path, '/up');
    });
  });

  group('sing-box JSON — сквозной путь', () {
    test('transport.path с query доезжает до тела дословно', () {
      final node = parseSingboxConfigs([
        {
          'outbounds': [
            _singboxOutbound('n', {'type': 'xhttp', 'path': _relayPath}),
          ],
        },
      ]).single;
      expect(((node as VlessSpec).transport! as XhttpTransport).path,
          _relayPath);
      final body =
          node.emit(TemplateVars.empty).map['transport'] as Map<String, dynamic>;
      expect(body['path'], _relayPath);
    });

    test('узлы, различные только query пути, — разные узлы (дедуп)', () {
      // Подпись дедупа — эмиссия узла: пока хвост срезался, релей-варианты
      // одного сервера с разными proxyip схлопывались в один.
      final nodes = parseSingboxConfigs([
        {
          'outbounds': [
            _singboxOutbound(
                'a', {'type': 'xhttp', 'path': '/?proxyip=1.1.1.1'}),
            _singboxOutbound(
                'b', {'type': 'xhttp', 'path': '/?proxyip=2.2.2.2'}),
          ],
        },
      ]);
      expect(nodes, hasLength(2));
      expect(
          nodes.map(
              (n) => ((n as VlessSpec).transport! as XhttpTransport).path),
          ['/?proxyip=1.1.1.1', '/?proxyip=2.2.2.2']);
    });
  });

  group('экспорт ссылки', () {
    test('? и & пути кодируются внутри параметра path', () {
      const path = '/base?x=1&proxyip=149.56.109.62';
      final uri = _node(const XhttpTransport(path: path)).toUri();
      // Сырая ссылка: разделители query пути не видны как разделители ссылки.
      expect(uri, contains('path=%2Fbase%3Fx%3D1%26proxyip%3D149.56.109.62'));
      final q = Uri.parse(uri).queryParameters;
      expect(q['path'], path);
      expect(q.containsKey('x'), isFalse);
      expect(q.containsKey('proxyip'), isFalse);
    });
  });

  // Записи реестра blocks.uri|xray.xhttp.path хвост не срезают с контракта
  // 1.1.115.
  group('ссылка и Xray-JSON — сквозной путь через реестр', () {
    test('URI: path=%2F%3Fproxyip%3D… → дословно, без кодов', () {
      final n = parseUri('vless://u-1@1.2.3.4:443?type=xhttp&security=none'
          '&path=%2F%3Fproxyip%3D149.56.109.62#n') as VlessSpec;
      expect((n.transport! as XhttpTransport).path, _relayPath);
      expect(n.warnings, isEmpty);
    });

    test('URI: path=/base?x=1 → дословно', () {
      final n = parseUri('vless://u-1@1.2.3.4:443?type=xhttp&security=none'
          '&path=/base?x=1#n') as VlessSpec;
      expect((n.transport! as XhttpTransport).path, '/base?x=1');
    });

    test('Xray-JSON: xhttpSettings.path с query → дословно', () {
      final nodes = parseXrayElement(_xrayElement({'path': _relayPath}));
      expect(nodes, hasLength(1));
      expect(((nodes.single as VlessSpec).transport! as XhttpTransport).path,
          _relayPath);
    });

    test('круг parseUri(toUri) сохраняет query пути', () {
      const path = '/base?x=1&proxyip=149.56.109.62';
      final back =
          parseUri(_node(const XhttpTransport(path: path)).toUri()) as VlessSpec;
      expect((back.transport! as XhttpTransport).path, path);
    });
  });
}
