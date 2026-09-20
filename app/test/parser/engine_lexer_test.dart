import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/engine/decoders.dart';
import 'package:lxbox/services/parser/engine/lexer.dart';

/// §480 W1 — лексер и декодеры, таблично.
///
/// Лексер режет текст и НИЧЕГО не декодирует, поэтому ожидания здесь сырые:
/// `%2F` остаётся `%2F`, `+` остаётся `+`. Кто и с какой семантикой их
/// раскроет, решает запись секции, а не лексер.
void main() {
  group('лексер: authority', () {
    // (имя, ссылка, host, port, port_raw)
    const cases = <(String, String, String, int?, String)>[
      ('обычный host:port', 'trojan://p@example.com:443#n', 'example.com', 443,
          '443'),
      ('без порта', 'trojan://p@example.com#n', 'example.com', null, ''),
      // Ради этого случая лексер и написан: Uri.tryParse отвергает ссылку
      // ЦЕЛИКОМ, то есть узел пропадает молча.
      ('multi-port: порт не число', 'hy2://p@example.com:443,20000-30000#n',
          'example.com', null, '443,20000-30000'),
      ('IPv6 в скобках с портом', 'trojan://p@[2001:db8::1]:443#n',
          '2001:db8::1', 443, '443'),
      ('IPv6 в скобках без порта', 'trojan://p@[::1]#n', '::1', null, ''),
      // Два и больше двоеточий без скобок — это адрес, а не host:port.
      ('голый IPv6 без скобок', 'trojan://p@2001:db8::1#n', '2001:db8::1', null,
          ''),
      ('порт не число', 'trojan://p@example.com:abc#n', 'example.com', null,
          'abc'),
    ];

    for (final (name, uri, host, port, portRaw) in cases) {
      test(name, () {
        final s = lexUri(uri)!;
        expect(s.host, host);
        expect(s.port, port);
        expect(s.portRaw, portRaw);
      });
    }
  });

  group('лексер: userinfo', () {
    // Режется по ПОСЛЕДНЕМУ `@`: внутри пароля `@` законен, в хосте — нет.
    const cases = <(String, String, String, String)>[
      ('простой', 'trojan://pass@h.com:443#n', 'pass', 'h.com'),
      ('с двоеточием — НЕ режется', 'trojan://pa:ss:1@h.com:443#n', 'pa:ss:1',
          'h.com'),
      ('с @ внутри', 'trojan://us@er@h.com:443#n', 'us@er', 'h.com'),
      ('сырой пробел', 'trojan://pa ss@h.com:443#n', 'pa ss', 'h.com'),
      ('сырой плюс остаётся плюсом', 'trojan://pa+ss@h.com:443#n', 'pa+ss',
          'h.com'),
      ('percent не снят', 'trojan://p%40ss@h.com:443#n', 'p%40ss', 'h.com'),
      ('нет userinfo', 'trojan://h.com:443#n', '', 'h.com'),
    ];

    for (final (name, uri, userinfo, host) in cases) {
      test(name, () {
        final s = lexUri(uri)!;
        expect(s.userinfo, userinfo);
        expect(s.host, host);
      });
    }
  });

  group('лексер: схема, путь, фрагмент', () {
    test('схема КАК НАПИСАНА, регистр и алиас не трогаются', () {
      expect(lexUri('HY2://p@h.com:443#n')!.scheme, 'HY2');
      expect(lexUri('naive+quic://p@h.com:443#n')!.scheme, 'naive+quic');
      expect(lexUri('proxy-https://p@h.com:443#n')!.scheme, 'proxy-https');
    });

    test('путь и фрагмент сырые', () {
      final s = lexUri('trojan://p@h.com:443/a%2Fb?x=1#My+Name%20Here')!;
      expect(s.path, '/a%2Fb');
      expect(s.fragment, 'My+Name%20Here');
    });

    test('фрагмент режется до query: `?` в метке законен', () {
      final s = lexUri('trojan://p@h.com:443?type=ws#what?why')!;
      expect(s.fragment, 'what?why');
      expect(s.query.get('type'), 'ws');
    });

    test('не ссылка — null', () {
      expect(lexUri(''), isNull);
      expect(lexUri('просто текст'), isNull);
      expect(lexUri('://h.com'), isNull);
    });
  });

  group('лексер: query упорядоченно', () {
    test('значения сырые: ни percent, ни плюс не тронуты', () {
      final q = lexQuery('a=x%2Fy&b=p+q');
      expect(q.get('a'), 'x%2Fy');
      expect(q.get('b'), 'p+q');
    });

    test('ключ без `=` — ключ с пустым значением', () {
      expect(lexQuery('flow&type=ws').get('flow'), '');
      expect(lexQuery('flow&type=ws').has('flow'), isTrue);
    });

    test('имя читается регистронезависимо', () {
      expect(lexQuery('SNI=a.com').get('sni'), 'a.com');
      expect(lexQuery('sni=a.com').get('SNI'), 'a.com');
    });

    // Норма §0.6: при двух написаниях побеждает ТОЧНОЕ совпадение, иначе
    // первое по порядку. У лаунчера здесь дефект — обход Go-map даёт
    // недетерминированный ответ между запусками.
    test('два написания: побеждает точное совпадение с каноном', () {
      expect(lexQuery('SNI=upper&sni=exact').get('sni'), 'exact');
    });

    test('два написания без точного: первое по порядку', () {
      expect(lexQuery('SNI=first&Sni=second').get('sni'), 'first');
    });

    test('дубль одного написания: первый', () {
      expect(lexQuery('fp=a&fp=b').get('fp'), 'a');
    });

    test('порядок появления сохранён', () {
      expect(lexQuery('b=1&a=2&c=3').names, ['b', 'a', 'c']);
    });
  });

  group('декодеры: семантика percent', () {
    // (имя, вход, режим, ожидание)
    const cases = <(String, String, DecodeMode, String)>[
      ('query: + это пробел', 'a+b', DecodeMode.query, 'a b'),
      ('path: + литерален', 'a+b', DecodeMode.path, 'a+b'),
      ('%2F одинаково в обоих', '%2Fx', DecodeMode.query, '/x'),
      ('%2F одинаково в обоих (path)', '%2Fx', DecodeMode.path, '/x'),
      ('UTF-8 из байтов', '%D0%BC%D0%B8%D1%80', DecodeMode.query, 'мир'),
      // Битый хвост НЕ роняет разбор и НЕ снимает значение: код о негодности
      // ставит санитайзер, с путём и значением.
      ('битый percent остаётся как есть', '%2Fx%zz', DecodeMode.path, '/x%zz'),
      ('одинокий %', 'a%', DecodeMode.path, 'a%'),
      ('пусто', '', DecodeMode.query, ''),
    ];

    for (final (name, input, mode, want) in cases) {
      test(name, () => expect(percentDecodeOnce(input, mode: mode), want));
    }
  });

  group('декодеры: decode_extra', () {
    test('path — ровно 2 прохода, плюс литерален на обоих', () {
      // Это D133-14: query-семантика на первом проходе дала бы «/a b».
      expect(decodeExtra('%2Fa+b', mode: DecodeMode.path, passes: 2), '/a+b');
      expect(
          decodeExtra('%252Fa%252Fb', mode: DecodeMode.path, passes: 2), '/a/b');
    });

    test('path не декодирует третий уровень', () {
      expect(decodeExtra('%25252Fx', mode: DecodeMode.path, passes: 2),
          '%2Fx');
    });

    test('alpn — до стабилизации: три уровня раскручиваются', () {
      expect(decodeExtra('http%25252F1.1', max: 16), 'http/1.1');
    });

    test('alpn — чистое значение не трогается', () {
      expect(decodeExtra('h2', max: 16), 'h2');
    });

    test('потолок проходов соблюдается', () {
      // Патологический вход: каждый проход снимает один уровень, и через 16
      // декодирование обязано остановиться, а не крутиться.
      var v = 'x';
      for (var i = 0; i < 40; i++) {
        v = v.replaceAll('%', '%25');
        v = '%25$v';
      }
      expect(() => decodeExtra(v, max: 16), returnsNormally);
    });
  });
}
