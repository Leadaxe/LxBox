import 'dart:convert';

import 'package:lxbox/config/config_parse.dart';
import 'package:lxbox/config/route_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('canonicalJsonForSingbox accepts JSON5 comments', () {
    const input = '''
{
  // line comment
  "a": 1,
  "b": [2, 3,], /* block */
}
''';
    final out = canonicalJsonForSingbox(input);
    final map = jsonDecode(out) as Map<String, dynamic>;
    expect(map['a'], 1);
    expect(map['b'], [2, 3]);
  });

  // §333 — json5 SyntaxException (не-FormatException, private в пакете)
  // нормализуется в FormatException с тем же message (координаты ошибки).
  test('canonicalJsonForSingbox normalizes json5 SyntaxException', () {
    expect(
      () => canonicalJsonForSingbox('{broken'),
      throwsA(isA<FormatException>()
          .having((e) => e.message, 'message', contains('at 1:'))),
    );
  });

  // §333 — изолятные обёртки: контракт идентичен sync-версиям.
  test('canonicalJsonForSingboxAsync matches sync on valid input', () async {
    const input = '{"a": 1, /* c */ "b": [2,],}';
    expect(await canonicalJsonForSingboxAsync(input),
        canonicalJsonForSingbox(input));
  });

  test('canonicalJsonForSingboxAsync throws FormatException with message',
      () async {
    await expectLater(
      canonicalJsonForSingboxAsync('{broken'),
      throwsA(isA<FormatException>()
          .having((e) => e.message, 'message', isNotEmpty)),
    );
  });

  // §686 п.11 — `#` ядро читает как строчный комментарий; JSON5 его не знает.
  test('canonicalJsonForSingbox accepts # comments of the core', () {
    const input = '''
# sing-box config
{
  "log": {"level": "info"}, # level
  // line comment
  "outbounds": [
    {"type": "vless", "tag": "#tag", "server": "h", /* b # */ "server_port": 1},
  ],
  "route": {"final": "vless://u@h:1#Name"}, # final
}
''';
    final map = jsonDecode(canonicalJsonForSingbox(input)) as Map;
    expect(map['log'], {'level': 'info'});
    expect((map['outbounds'] as List).single['tag'], '#tag');
    expect(map['route']['final'], 'vless://u@h:1#Name');
    expect(formatJson5(input), contains('"#tag"'));
    expect(prettyJsonForDisplay(input), isNot(input));
    expect(RouteConfig.finalTag(input), 'vless://u@h:1#Name');
  });

  test('hasJson5Comments sees # outside strings only', () {
    expect(hasJson5Comments('{"a": 1} # c'), isTrue);
    expect(hasJson5Comments('{"u": "vless://h#Name"}'), isFalse);
    expect(hasJson5Comments(r"{k: 'it\'s #1'}"), isFalse);
  });

  test('prettyJsonForDisplayAsync matches sync', () async {
    const input = '{"a":1}';
    expect(await prettyJsonForDisplayAsync(input),
        prettyJsonForDisplay(input));
    // Невалидный вход возвращается as-is (контракт sync-версии).
    expect(await prettyJsonForDisplayAsync('{oops'), '{oops');
  });
}
