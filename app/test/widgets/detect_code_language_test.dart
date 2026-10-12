import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';

/// §624 — язык подсветки по первой непустой строке текста.
void main() {
  const json = LxCodeLanguage.json;
  const ini = LxCodeLanguage.ini;
  const uri = LxCodeLanguage.uri;

  final cases = <String, (String, LxCodeLanguage?)>{
    'объект': ('{"type": "vless"}', json),
    'недописанный объект': ('{"type": "direct"', json),
    'объект с отступом и пустыми строками': ('\n\n   {\n  "a": 1\n}', json),
    'массив объектов': ('[\n  {"tag": "a"}\n]', json),
    'пустой массив': ('[]', json),
    'массив на одной строке': ('[ {', json),
    'массив строк': ('["a", "b"]', json),
    'WireGuard [Interface]': (
      '[Interface]\nPrivateKey = abc\nAddress = 10.0.0.2/32\n\n[Peer]',
      ini
    ),
    '[Peer] первым': ('[Peer]\nEndpoint = 1.2.3.4:51820', ini),
    'секция с пробелом и дефисом': ('[My Section-1]\nkey = v', ini),
    '[Interface] с BOM': ('\uFEFF[Interface]\nPrivateKey = abc', ini),
    'комментарий # и ключ = значение': ('# exported\nPrivateKey = abc', ini),
    'комментарий ; и секция': ('; note\n\n[Interface]', ini),
    'комментарий и не INI': ('# list\nvless://u@h:443', null),
    'одни комментарии': ('# a\n# b', null),
    'ссылка vless': ('vless://uuid@example.com:443?security=reality#Node', uri),
    'список ссылок': ('vless://a@h1:443\ntrojan://b@h2:443', uri),
    'схема с плюсом и точкой': ('proxy+http.x://h:1', uri),
    'base64-подписка': ('dmxlc3M6Ly91dWlkQGV4YW1wbGUuY29tOjQ0Mw==', null),
    'YAML': ('proxies:\n  - name: a', null),
    'пустой текст': ('', null),
    'одни пробелы': ('   \n\t\n  ', null),
  };

  for (final MapEntry(key: name, value: (text, expected)) in cases.entries) {
    test(name, () => expect(detectCodeLanguage(text), expected));
  }
}
