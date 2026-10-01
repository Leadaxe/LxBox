import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/engine/emitter.dart';
import 'package:lxbox/services/parser/engine/interpreter.dart';
import 'package:lxbox/services/parser/engine/section.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';

import 'engine_test_setup.dart';

MapperSection _section(Map<String, dynamic> json) =>
    MapperSection.fromJson('uri', 'x', json);

String _emit(Map<String, dynamic> section, Map<String, dynamic> body,
        {String label = ''}) =>
    emitViaSection(_section(section), body, label)!.uri;

void main() {
  setUpAll(loadEngineSections);

  group('§495 Q133-70 · канон имени = первый source', () {
    test('имя записи ≠ source — пишется query-ключ из source', () {
      expect(
        _emit(
          {
            'detect': {'scheme_in': ['s']},
            'emit': {'form': 'url', 'param_order': 'alphabetical'},
            'params': {
              'server': {'source': 'host', 'maps_to': 'server'},
              'server_port': {'source': 'port', 'maps_to': 'server_port'},
              'tls_legacy': {
                'source': 'query.tls',
                'maps_to': 'tls.enabled',
                'type': 'bool_spelled',
                'value_map': {'1': true, 'true': true},
              },
            },
          },
          {
            'server': 'h',
            'server_port': 443,
            'tls': {'enabled': true},
          },
        ),
        's://h:443?tls=1',
      );
    });

    test('emit.names сильнее source', () {
      expect(
        _emit(
          {
            'emit': {
              'form': 'url',
              'names': {'insecure': 'allowInsecure'},
            },
            'params': {
              'server': {'source': 'host', 'maps_to': 'server'},
              'server_port': {'source': 'port', 'maps_to': 'server_port'},
              'insecure': {
                'source': ['query.insecure', 'query.allowInsecure'],
                'maps_to': 'tls.insecure',
                'type': 'bool_spelled',
              },
            },
          },
          {
            'server': 'h',
            'server_port': 1,
            'tls': {'insecure': true},
          },
        ),
        'x://h:1?allowInsecure=true',
      );
    });
  });

  group('§495 Q133-71 · пустой ключ sets не пишется', () {
    const section = {
      'detect': {'scheme_in': ['s']},
      'emit': {
        'form': 'url',
        'param_order': 'alphabetical',
        'omit_default': ['sec'],
      },
      'params': {
        'server': {'source': 'host', 'maps_to': 'server'},
        'server_port': {'source': 'port', 'maps_to': 'server_port'},
        'sec': {
          'source': 'query.sec',
          'selector': true,
          'sets': {
            'tls': {'tls.enabled': true, 'tls.utls.enabled': true},
            '': {'tls.enabled': true},
          },
        },
      },
    };

    test('конкретная ветка, а не пустой ключ-умолчание', () {
      expect(
        _emit(section, {
          'server': 'h',
          'server_port': 1,
          'tls': {'enabled': true, 'utls': {'enabled': true}},
        }),
        's://h:1?sec=tls',
      );
    });

    test('пустой ключ не даёт sec=', () {
      expect(
        _emit(section, {'server': 'h', 'server_port': 1}),
        's://h:1',
      );
    });
  });

  group('§495 Q133-72 · decode_extra.passes на выходе', () {
    const section = {
      'detect': {'scheme_in': ['s']},
      'emit': {'form': 'url', 'param_order': 'alphabetical'},
      'params': {
        'server': {'source': 'host', 'maps_to': 'server'},
        'server_port': {'source': 'port', 'maps_to': 'server_port'},
        'path': {
          'source': 'query.path',
          'maps_to': 'transport.path',
          'decode_extra': {'mode': 'path', 'passes': 2},
        },
      },
    };

    test('значение с % переживает круг parse(emit)', () {
      const body = {
        'server': 'h',
        'server_port': 443,
        'transport': {'path': '/%2F'},
      };
      final uri = _emit(section, body);
      final back = runSection(_section(section), uri)!;
      expect((back.body['transport'] as Map)['path'], '/%2F');
      expect(uri, isNot(contains('path=//')));
    });

    test('без % в значении лишний проход не добавляется', () {
      expect(
        _emit(section, {
          'server': 'h',
          'server_port': 443,
          'transport': {'path': '/x'},
        }),
        's://h:443?path=%2Fx',
      );
    });
  });

  group('§495 Q133-73 · составное имя уступает хозяину пути', () {
    const section = {
      'detect': {'scheme_in': ['s']},
      'emit': {'form': 'url', 'param_order': 'alphabetical'},
      'params': {
        'server': {'source': 'host', 'maps_to': 'server'},
        'server_port': {'source': 'port', 'maps_to': 'server_port'},
        'flow': {
          'source': 'query.flow',
          'maps_to': 'flow',
          // Тождественная пара нужна, иначе `_isUntranslatedCanon` уже
          // удерживает канон и новый приоритет хозяина пути не исполняется.
          'value_map': {
            'xtls-rprx-vision-udp443': 'xtls-rprx-vision',
            'xtls-rprx-vision': 'xtls-rprx-vision',
          },
          'sets': {
            'xtls-rprx-vision-udp443': {'packet_encoding': 'xudp'},
          },
        },
        'packetEncoding': {
          'source': 'query.packetEncoding',
          'maps_to': 'packet_encoding',
        },
      },
    };

    test('packet_encoding пишет хозяин, flow — канон без суффикса', () {
      expect(
        _emit(section, {
          'server': 'h',
          'server_port': 443,
          'flow': 'xtls-rprx-vision',
          'packet_encoding': 'xudp',
        }),
        's://h:443?flow=xtls-rprx-vision&packetEncoding=xudp',
      );
    });
  });

  group('§495 Q133-75 · round_trip_only: emit (detour)', () {
    test('эмиттер пишет detour из тела', () {
      final section = MapperSections.I.sectionFor('uri', 'vless')!;
      final body = <String, dynamic>{
        'type': 'vless',
        'server': 'h.example',
        'server_port': 443,
        'uuid': '11111111-1111-1111-1111-111111111111',
        'detour': 'relay',
      };
      final uri = emitViaSection(section, body, 'n')!.uri;
      expect(uri, contains('detour=relay'));
    });

    test('разбором detour из ссылки не читается', () {
      final section = MapperSections.I.sectionFor('uri', 'vless')!;
      final uri =
          'vless://11111111-1111-1111-1111-111111111111@h:443?detour=relay#n';
      final out = runSection(section, uri)!;
      expect(out.body['detour'], isNull);
    });
  });
}
