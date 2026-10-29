import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/json_comments.dart';

// §686 п.11 — сканер комментариев: `#` до конца строки вне строк, как у ядра;
// строку открывают `"` и `'`, закрывает та же кавычка, `\` берёт пару.
void main() {
  group('stripJsonComments: строгий JSON', () {
    test('`#` вне строки снимается до конца строки вместе с пробелами', () {
      expect(stripJsonComments('{"a": 1, # c\n"b": 2}'),
          '{"a": 1,\n"b": 2}');
      expect(stripJsonComments('# head\n{"a": 1}'), '\n{"a": 1}');
      expect(stripJsonComments('{"a": 1} # tail'), '{"a": 1}');
    });

    test('`//` и `/* */` снимаются, как раньше', () {
      expect(stripJsonComments('{"a": 1 // c\n}'), '{"a": 1\n}');
      expect(stripJsonComments('{/* c */"a": 1}'), '{"a": 1}');
    });

    test('`#` внутри строки не трогается', () {
      expect(stripJsonComments('{"u": "vless://x@h:1#Name"}'), isNull);
      expect(stripJsonComments('{"f": "#fragment"}'), isNull);
    });

    test('пограничные случаи кавычек и экранов', () {
      // `\"` не закрывает строку.
      expect(stripJsonComments(r'{"k": "a\"#b"}'), isNull);
      // `\\` — пара; строка закрыта, дальше комментарий.
      expect(stripJsonComments('{"k": "a\\\\" # c\n}'), '{"k": "a\\\\"\n}');
      // `\'` не закрывает одинарную строку.
      expect(stripJsonComments(r"{k: 'it\'s #1'}"), isNull);
      // `'` внутри `"…"` строку не переключает.
      expect(stripJsonComments('{"k": "don\'t #x"}'), isNull);
      // `"` внутри `'…'` строку не переключает.
      expect(stripJsonComments('{k: \'say "#hi"\'}'), isNull);
      // JSON5: `\` + перевод строки — строка продолжается.
      expect(stripJsonComments('{k: "line\\\n#more"}'), isNull);
    });

    test('кавычка и `#` в комментарии ничего не переключают', () {
      expect(stripJsonComments("{\"a\": 1 // don't\n}"), '{"a": 1\n}');
      expect(stripJsonComments('{/* it\'s # */"a": 1}'), '{"a": 1}');
    });
  });

  group('stripJsonComments: режим JSON5', () {
    test('снимается только `#`', () {
      expect(stripJsonComments('{a: 1, # c\nb: 2}', json5: true),
          '{a: 1,\nb: 2}');
    });

    test('`//` и `/* */` остаются пакету json5', () {
      const text = '{a: 1, // c\n/* d */ b: 2}';
      expect(stripJsonComments(text, json5: true), isNull);
      // `#` внутри них — часть комментария, не новый комментарий.
      const inner = "{/* x # y */ a: 1, // it's # z\nb: 2}";
      expect(stripJsonComments(inner, json5: true), isNull);
      expect(stripJsonComments('{/* x */ a: 1, # t\n}', json5: true),
          '{/* x */ a: 1,\n}');
    });

    test('пограничные случаи строк — те же', () {
      expect(stripJsonComments(r"{k: 'it\'s #1'}", json5: true), isNull);
      expect(stripJsonComments('{k: "line\\\n#more"}', json5: true), isNull);
      expect(stripJsonComments('{k: "a\\\\" # c\n}', json5: true),
          '{k: "a\\\\"\n}');
    });
  });

  test('uncommentedJson: узел с `#` становится строгим JSON', () {
    const node = '{\n'
        '  "type": "vless", # United States Central\n'
        '  "tag": "us-1",\n'
        '  "server": "h.example", "server_port": 443, # port\n'
        '  "uuid": "u", "flow": "#keep"\n'
        '}';
    final out = uncommentedJson(node);
    expect(out, isNotNull);
    expect(out, isNot(contains('United States')));
    expect(out, contains('"#keep"'));
  });
}
