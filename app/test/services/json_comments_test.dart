import 'dart:convert';

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

  // §741 (контракт 1.1.172) — случаи, названные лаунчером (TASKS_LXBOX §173).
  group('§741 jsonSourceText', () {
    const commented = '// пометка: основной сервер, «ключ» менять в декабре\n'
        '{\n'
        '  "type": "trojan", /* блочный "комментарий" с кавычками */\n'
        '  "server": "example-2.com",\n'
        '  "server_port": 443, # решётка до конца строки\n'
        '  "password": "pass//not#comment/*x*/",\n'
        '  "tls": {"enabled": true, "server_name": "example-2.com"}\n'
        '}';

    test('кавычки в /* */, //, # и /* внутри строки пароля', () {
      final v = jsonDecode(jsonSourceText(commented)) as Map;
      expect(v['password'], 'pass//not#comment/*x*/');
      expect(v['server_port'], 443);
      expect((v['tls'] as Map)['server_name'], 'example-2.com');
    });

    test('текст, начинающийся с комментария, опознаётся как JSON', () {
      expect(uncommentedJson('# head\n{"a": 1}'), '\n{"a": 1}');
      expect(uncommentedJson('/* x */ [1]'), ' [1]');
    });

    test('ссылка, .conf и JSON без комментариев — как есть', () {
      const uri = 'vless://u@h:1?x=1#Name // x';
      expect(jsonSourceText(uri), uri);
      const ini = '# c\n[Interface]\nPrivateKey = a/b+c=\n';
      expect(jsonSourceText(ini), ini);
      const plain = '{"a": "#x"}';
      expect(identical(jsonSourceText(plain), plain), isTrue);
    });

    test('экранированная кавычка в строке не закрывает её', () {
      expect(jsonDecode(jsonSourceText(r'{"p": "a\"//b" // c' '\n}')),
          {'p': r'a"//b'});
    });

    test('незакрытый /* съедает текст до конца — не JSON', () {
      expect(uncommentedJson('{"a": 1} /* tail'), '{"a": 1} ');
      expect(uncommentedJson('{"a": /* 1}'), isNull);
    });
  });

  group('§741 withJsonTag', () {
    test('нет ключа tag — первым ключом с отступом следующей строки', () {
      const text = '{\n  // c\n  "type": "trojan" # t\n}';
      final out = withJsonTag(text, 'n1')!;
      expect(out, '{\n  "tag": "n1",\n  // c\n  "type": "trojan" # t\n}');
      expect(jsonDecode(jsonSourceText(out)), {'tag': 'n1', 'type': 'trojan'});
    });

    test('однострочный и с комментарием перед {', () {
      expect(withJsonTag('{"type": "x"}', 'a'), '{"tag": "a", "type": "x"}');
      expect(withJsonTag('// h\n{"type": "x"}', 'a'),
          '// h\n{"tag": "a", "type": "x"}');
    });

    test('ключ tag есть — меняется только значение; вложенный tag не трогается',
        () {
      const text = '{"tls": {"tag": "in"}, /* "tag": "c" */ "tag": "old" # x\n}';
      expect(withJsonTag(text, 'new "q"'),
          '{"tls": {"tag": "in"}, /* "tag": "c" */ "tag": "new \\"q\\"" # x\n}');
    });

    test('строка "tag" как значение ключом не считается', () {
      const text = '{"name": "tag", "type": "x"}';
      expect(withJsonTag(text, 'a'), '{"tag": "a", "name": "tag", "type": "x"}');
    });

    test('не объект, пустой объект, tag не строка — null', () {
      expect(withJsonTag('[1]', 'a'), isNull);
      expect(withJsonTag('{ /* c */ }', 'a'), isNull);
      expect(withJsonTag('{"tag": 1}', 'a'), isNull);
    });
  });
}
