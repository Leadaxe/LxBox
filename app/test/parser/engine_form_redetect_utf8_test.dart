import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/engine/decoders.dart';
import 'package:lxbox/services/parser/engine/interpreter.dart';
import 'package:lxbox/services/parser/engine/section.dart';

/// Выбор формы по раскрытому тексту (unwrap → redetect) и серия битых байтов
/// UTF-8 → один U+FFFD (контракт 1.1.74/1.1.75, MAPPER_ENGINE §1).
///
/// Секции синтетические, тип тела `probe`: имён схем движок не знает.
MapperSection _section(List<Map<String, dynamic>> forms) =>
    MapperSection.fromJson('uri', 'probe', {
      'body_source': 'uri',
      'forms': forms,
      'params': {
        'server': {'source': 'host', 'maps_to': 'server'},
        'server_port': {
          'source': 'port',
          'maps_to': 'server_port',
          'type': 'int',
        },
      },
    });

const _unwrap = [
  {'decoder': 'base64', 'scope': 'authority'},
  {'reparse': 'url'},
];

String _b64(String s) => base64.encode(utf8.encode(s));

void main() {
  group('detect формы с оболочкой — по сырому ИЛИ раскрытому тексту', () {
    // Предикат про то, что ПОД оболочкой: на блобе `@` нет.
    final revealed = _section([
      {
        'id': 'revealed',
        'detect': {'regex': r'^[^#]*@'},
        'decode': _unwrap,
        'space': 'url',
      },
    ]);

    test('структура под base64 опознаёт форму', () {
      final res = runSection(revealed, 'x://${_b64('u:p@h.example:443')}#n');
      expect(res, isNotNull);
      expect(res!.body['server'], 'h.example');
      expect(res.body['server_port'], 443);
    });

    test('раскрытый текст без объявленной структуры — форма не отвечает', () {
      expect(runSection(revealed, 'x://${_b64('no-structure-here')}#n'),
          isNull);
    });

    test('предикат про САМУ оболочку по-прежнему судится по сырому', () {
      final wrapped = _section([
        {
          'id': 'wrapped',
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
          'decode': _unwrap,
          'space': 'url',
        },
      ]);
      final res = runSection(wrapped, 'x://${_b64('u@h.example:8443')}');
      expect(res?.body['server'], 'h.example');
    });
  });

  group('серия невалидных байтов UTF-8 → один U+FFFD', () {
    test('шесть байт cp1251 подряд — одна замена', () {
      final bytes = [
        ...utf8.encode('Node-'),
        0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, //
        ...utf8.encode('-1'),
      ];
      expect(decodeUtf8Lenient(bytes), 'Node-\uFFFD-1');
      expect(percentDecodeOnce('Node-%CF%F0%E8%E2%E5%F2-1',
          mode: DecodeMode.path), 'Node-\uFFFD-1');
    });

    test('серии, разделённые валидным символом, — по замене на каждую', () {
      expect(decodeUtf8Lenient([0xFF, 0xFE, 0x41, 0xC0, 0x80]),
          '\uFFFDA\uFFFD');
    });

    test('U+FFFD источника остаётся отдельным символом', () {
      // EF BF BD — честно закодированный U+FFFD, за ним серия битых байтов.
      expect(decodeUtf8Lenient([0xEF, 0xBF, 0xBD, 0xFF, 0xFE]),
          '\uFFFD\uFFFD');
    });

    test('обрыв многобайтовой, overlong и суррогат — невалидны', () {
      expect(decodeUtf8Lenient([0x61, 0xE2, 0x82]), 'a\uFFFD');
      expect(decodeUtf8Lenient([0xE0, 0x80, 0x80, 0x62]), '\uFFFDb');
      expect(decodeUtf8Lenient([0xED, 0xA0, 0x80]), '\uFFFD');
      expect(decodeUtf8Lenient(utf8.encode('Привет €𝄞')), 'Привет €𝄞');
    });
  });
}
