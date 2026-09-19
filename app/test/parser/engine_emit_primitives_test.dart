import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/engine/emitter.dart';
import 'package:lxbox/services/parser/engine/section.dart';

/// §480 W7 — ЮНИТ-ТЕСТЫ ОБРАТИМОСТИ примитивов эмита.
///
/// Секции здесь собираются вручную из JSON: проверяется ГРАММАТИКА, а не
/// конкретный протокол, и настоящая секция притащила бы в тест имя схемы и
/// полтора десятка записей, к делу не относящихся.
MapperSection _section(Map<String, dynamic> json) =>
    MapperSection.fromJson('uri', 'x', json);

String _emit(Map<String, dynamic> section, Map<String, dynamic> body,
        {String label = ''}) =>
    emitViaSection(_section(section), body, label)!.uri;

void main() {
  group('§480 W7 · value_map⁻¹', () {
    test('инъективная таблица обращается', () {
      expect(invertValueMap({'chrome': 'hellochrome'}), {'hellochrome': 'chrome'});
    });

    test('НЕинъективная таблица обращения не даёт — выбирать нечем', () {
      // Два написания в одно значение тела: тихий выбор первого переписывал
      // бы ссылки живых узлов.
      expect(invertValueMap({'a': 'same', 'b': 'same'}), isNull);
    });

    test('ветка со значением null из обращения выпадает', () {
      // `null` означает «поле не ставится», а не «значение такое».
      expect(invertValueMap({'random': null, 'chrome': 'hellochrome'}),
          {'hellochrome': 'chrome'});
    });

    test('таблица из одних null обращения не даёт', () {
      expect(invertValueMap({'random': null}), isNull);
    });
  });

  group('§480 W7 · сериализация query', () {
    const base = {
      'detect': {
        'scheme_in': ['s']
      },
      'emit': {'form': 'url', 'param_order': 'alphabetical'},
      'params': {
        'server': {'source': 'host', 'maps_to': 'server'},
        'server_port': {'source': 'port', 'maps_to': 'server_port'},
        'b': {'source': 'query.b', 'maps_to': 'b'},
        'a': {'source': 'query.a', 'maps_to': 'a'},
      },
    };

    test('порядок параметров алфавитный, а не порядок объявления', () {
      final uri = _emit(base, {'server': 'h', 'server_port': 1, 'b': '2', 'a': '1'});
      expect(uri, 's://h:1?a=1&b=2');
    });

    test('пробел кодируется %20, не «+»', () {
      expect(_emit(base, {'server': 'h', 'server_port': 1, 'a': 'x y'}),
          's://h:1?a=x%20y');
    });

    test('литеральный «+» кодируется %2B — иначе чтение вернёт пробел', () {
      // Чтение декодирует «+» как пробел (form-encoding). Без %2B base64-ключ
      // вернулся бы с пробелом — D133-7.
      expect(_emit(base, {'server': 'h', 'server_port': 1, 'a': 'x+y'}),
          's://h:1?a=x%2By');
    });

    test('IPv6 в скобках', () {
      expect(_emit(base, {'server': '2001:db8::1', 'server_port': 1}),
          's://[2001:db8::1]:1');
    });

    test('метка уезжает во фрагмент', () {
      expect(_emit(base, {'server': 'h', 'server_port': 1}, label: 'имя'),
          's://h:1#%D0%B8%D0%BC%D1%8F');
    });
  });

  group('§480 W7 · sets⁻¹', () {
    const section = {
      'detect': {
        'scheme_in': ['s']
      },
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
            'on': {'tls.enabled': true},
            'off': {'tls': null},
            '': {'tls.enabled': true},
          },
        },
      },
    };

    test('значение, совпавшее с умолчанием, не пишется', () {
      expect(_emit(section, {'server': 'h', 'server_port': 1, 'tls': {'enabled': true}}),
          's://h:1');
    });

    test('ветка-ОТРИЦАНИЕ пишется, хотя имя в omit_default', () {
      // Не напиши мы её — разбор поднял бы tls веткой умолчания, и узел без
      // шифрования стал бы узлом с ним.
      expect(_emit(section, {'server': 'h', 'server_port': 1}), 's://h:1?sec=off');
    });
  });

  group('§480 W7 · источник записи', () {
    test('запись, читающая не query, параметром не повторяется', () {
      // Адрес несёт authority; продублируй его эмиттер — вышло бы
      // `?server=h&server_port=1` рядом с тем же адресом.
      final uri = _emit(const {
        'detect': {
          'scheme_in': ['s']
        },
        'emit': {'form': 'url'},
        'params': {
          'server': {'source': 'host', 'maps_to': 'server'},
          'server_port': {'source': 'port', 'maps_to': 'server_port'},
        },
      }, {'server': 'h', 'server_port': 1});
      expect(uri, 's://h:1');
    });
  });

  group('§480 W7 · userinfo into⁻¹', () {
    Map<String, dynamic> withUserinfo(Map<String, dynamic> ui) => {
          'detect': {
            'scheme_in': ['s']
          },
          'emit': {'form': 'url'},
          'userinfo': ui,
          'params': {
            'server': {'source': 'host', 'maps_to': 'server'},
            'server_port': {'source': 'port', 'maps_to': 'server_port'},
          },
        };

    test('один слот — весь userinfo целиком', () {
      expect(
          _emit(withUserinfo({'into': ['password']}),
              {'server': 'h', 'server_port': 1, 'password': 'p@ss:word'}),
          's://p%40ss%3Aword@h:1');
    });

    test('два слота — через разделитель', () {
      expect(
          _emit(
              withUserinfo({
                'split': {'sep': ':', 'limit': 2},
                'into': ['user', 'pass'],
              }),
              {'server': 'h', 'server_port': 1, 'user': 'u', 'pass': 'p'}),
          's://u:p@h:1');
    });

    test('пустая голова, непустой хвост — форма «:pass@»', () {
      expect(
          _emit(
              withUserinfo({
                'split': {'sep': ':', 'limit': 2},
                'into': ['user', 'pass'],
              }),
              {'server': 'h', 'server_port': 1, 'pass': 'p'}),
          's://:p@h:1');
    });

    test('одиночное имя при single_into=ВТОРОЙ слот несёт двоеточие', () {
      // §465: без «:» узел вернулся бы с именем в слоте пароля.
      expect(
          _emit(
              withUserinfo({
                'split': {'sep': ':', 'limit': 2},
                'into': ['user', 'pass'],
                'single_into': 'pass',
              }),
              {'server': 'h', 'server_port': 1, 'user': 'u'}),
          's://u:@h:1');
    });

    test('одиночное имя при single_into=ПЕРВЫЙ слот двоеточия не несёт', () {
      expect(
          _emit(
              withUserinfo({
                'split': {'sep': ':', 'limit': 2},
                'into': ['user', 'pass'],
                'single_into': 'user',
              }),
              {'server': 'h', 'server_port': 1, 'user': 'u'}),
          's://u@h:1');
    });

    test('оба пусто — userinfo нет вовсе', () {
      expect(
          _emit(
              withUserinfo({
                'split': {'sep': ':', 'limit': 2},
                'into': ['user', 'pass'],
              }),
              {'server': 'h', 'server_port': 1}),
          's://h:1');
    });
  });

  group('§480 W7 · form_from (scheme_sets⁻¹)', () {
    const section = {
      'detect': {
        'scheme_in': ['s5']
      },
      'emit': {
        'form': 'url',
        'form_from': {
          'version': {'4': 's4', '*': 's5'}
        },
      },
      'scheme_sets': {
        's4': {'version': '4'},
        's5': {'version': '5'},
      },
      'params': {
        'server': {'source': 'host', 'maps_to': 'server'},
        'server_port': {'source': 'port', 'maps_to': 'server_port'},
      },
    };

    test('написание схемы восстанавливается по телу', () {
      expect(_emit(section, {'server': 'h', 'server_port': 1, 'version': '4'}),
          's4://h:1');
    });

    test('ветка «*» — всё остальное', () {
      expect(_emit(section, {'server': 'h', 'server_port': 1, 'version': '5'}),
          's5://h:1');
    });
  });

  group('§480 W7 · emit.omit_port', () {
    test('порт, равный объявленному, опускается', () {
      const section = {
        'detect': {
          'scheme_in': ['s']
        },
        'emit': {'form': 'url', 'omit_port': 443},
        'params': {
          'server': {'source': 'host', 'maps_to': 'server'},
          'server_port': {'source': 'port', 'maps_to': 'server_port'},
        },
      };
      expect(_emit(section, {'server': 'h', 'server_port': 443}), 's://h');
      expect(_emit(section, {'server': 'h', 'server_port': 8443}), 's://h:8443');
    });
  });

  group('§480 W7 · потери на круге', () {
    test('путь, никуда не уехавший, объявлен потерей', () {
      final r = emitViaSection(
        _section(const {
          'detect': {
            'scheme_in': ['s']
          },
          'emit': {'form': 'url'},
          'params': {
            'server': {'source': 'host', 'maps_to': 'server'},
          },
        }),
        {'server': 'h', 'orphan': 'v'},
        '',
      )!;
      expect(r.lost, ['orphan']);
    });

    test('round_trip:false снимает путь с учёта — потеря ОБЪЯВЛЕНА', () {
      final r = emitViaSection(
        _section(const {
          'detect': {
            'scheme_in': ['s']
          },
          'emit': {'form': 'url'},
          'params': {
            'server': {'source': 'host', 'maps_to': 'server'},
            'x': {
              'source': 'query.x',
              'maps_to': 'orphan',
              'round_trip': false,
              'round_trip_why': 'в ссылке этого поля нет ни у одного клиента',
            },
          },
        }),
        {'server': 'h', 'orphan': 'v'},
        '',
      )!;
      expect(r.lost, isEmpty);
      expect(r.uri, 's://h');
    });
  });

  test('секция без блока emit обратного хода не даёт', () {
    expect(
        emitViaSection(
            _section(const {'params': <String, dynamic>{}}), const {}, ''),
        isNull);
  });
}
