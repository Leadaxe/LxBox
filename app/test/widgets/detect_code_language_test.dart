// §749 — язык редактора по виду текста: JSON с ведущим комментарием.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/json_comments.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';

void main() {
  group('detectCodeLanguage', () {
    test('обычный JSON-объект и массив', () {
      expect(detectCodeLanguage('{"type": "vless"}'), LxCodeLanguage.json);
      expect(detectCodeLanguage('\n  [1, 2]'), LxCodeLanguage.json);
    });

    test('JSON с ведущим // — JSON', () {
      expect(
        detectCodeLanguage('// United States Central\n{\n  "type": "vless"\n}'),
        LxCodeLanguage.json,
      );
    });

    test('JSON с ведущим /* */ — JSON, и многострочным тоже', () {
      expect(detectCodeLanguage('/* note */ {"a": 1}'), LxCodeLanguage.json);
      expect(
        detectCodeLanguage('/* line 1\n   line 2 */\n[{"a": 1}]'),
        LxCodeLanguage.json,
      );
    });

    test('JSON с ведущим # — JSON', () {
      expect(
        detectCodeLanguage('# my server\n# second\n{\n  "a": 1\n}'),
        LxCodeLanguage.json,
      );
      expect(detectCodeLanguage('# list\n["a", "b"]'), LxCodeLanguage.json);
    });

    test('BOM и пустые строки перед комментарием', () {
      expect(
        detectCodeLanguage('﻿\n\n// x\n{"a": 1}'),
        LxCodeLanguage.json,
      );
    });

    test('WG .conf с ведущими # и ; — по-прежнему INI', () {
      expect(
        detectCodeLanguage(
          '# WireGuard\n; comment\n[Interface]\nPrivateKey = x',
        ),
        LxCodeLanguage.ini,
      );
      expect(
        detectCodeLanguage('# c\nPrivateKey = x\n[Peer]'),
        LxCodeLanguage.ini,
      );
      expect(
        detectCodeLanguage('[Interface]\nAddress = 10.0.0.2/32'),
        LxCodeLanguage.ini,
      );
    });

    test('ссылки — не JSON', () {
      expect(
        detectCodeLanguage('vless://uuid@host:443?type=tcp#name'),
        LxCodeLanguage.uri,
      );
      expect(detectCodeLanguage('// c\nvless://uuid@host:443#{x}'), isNull);
    });

    test('комментарий без JSON, base64 и пустой текст — null', () {
      expect(detectCodeLanguage('// only a note'), isNull);
      expect(detectCodeLanguage('# only a note'), isNull);
      expect(detectCodeLanguage('/* never closed {"a": 1}'), isNull);
      expect(detectCodeLanguage('dmxlc3M6Ly8='), isNull);
      expect(detectCodeLanguage('  \n '), isNull);
    });
  });

  test('jsonLeadChar пропускает пробелы, BOM и комментарии', () {
    expect(jsonLeadChar('﻿ // a\n /* b */ # c\n {'), '{');
    expect(jsonLeadChar('"s"'), '"');
    expect(jsonLeadChar('// x'), '');
    expect(jsonLeadChar(''), '');
  });
}
