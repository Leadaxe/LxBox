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

    test('НЕинъективная таблица: побеждает ПЕРВОЕ объявленное написание', () {
      // Несколько написаний в одно значение тела — норма живой записи
      // («on», «true», «1» — всё это «включено»). Канон объявлен ПОРЯДКОМ, тем
      // же правилом, что и каноническое имя параметра (первое в `aliases`).
      expect(invertValueMap({'on': 'true', 'true': 'true', '1': 'true'}),
          {'true': 'on'});
    });

    test('пустой ключ — «параметра не было», обратно не пишется', () {
      expect(invertValueMap({'': 'auto', 'aes': 'aes'}), {'aes': 'aes'});
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

    test('consumed первого элемента массива не покрывает остальные', () {
      // Ссылка несёт один набор параметров: `_read('hops[]…')` берёт
      // первый объект. Без индексных путей второй объект числился бы
      // уехавшим — тот же `hops[].key` уже в `_consumed`.
      final r = emitViaSection(
        _section(const {
          'detect': {
            'scheme_in': ['s']
          },
          'emit': {'form': 'url'},
          'params': {
            'server': {'source': 'host', 'maps_to': 'hops[].host'},
            'k': {'source': 'query.k', 'maps_to': 'hops[].key'},
          },
        }),
        {
          'hops': [
            {'host': 'a.example', 'key': 'one'},
            {'host': 'b.example', 'key': 'two'},
          ],
        },
        '',
      )!;
      expect(r.uri, 's://a.example?k=one');
      expect(r.lost, containsAll(['hops[1].host', 'hops[1].key']));
    });
  });

  group('§480 W7 · emit.refuse_when', () {
    const section = {
      'detect': {
        'scheme_in': ['s']
      },
      'emit': {
        'form': 'url',
        'refuse_when': [
          {'path': 'hops', 'len_gt': 1},
        ],
      },
      'params': {
        'server': {'source': 'host', 'maps_to': 'hops[].host'},
      },
    };

    test('длина больше порога — ссылки нет (как у схемы без share_uri)', () {
      final r = emitViaSection(
        _section(section),
        {
          'hops': [
            {'host': 'a.example'},
            {'host': 'b.example'},
          ],
        },
        '',
      );
      expect(r, isNotNull, reason: 'секция emit объявила — это не «нет хода»');
      expect(r!.uri, isEmpty);
    });

    test('один элемент — ссылка собирается', () {
      expect(
        emitViaSection(
          _section(section),
          {
            'hops': [
              {'host': 'a.example'},
            ],
          },
          '',
        )!.uri,
        's://a.example',
      );
    });
  });

  test('секция без блока emit обратного хода не даёт', () {
    expect(
        emitViaSection(
            _section(const {'params': <String, dynamic>{}}), const {}, ''),
        isNull);
  });
  group('§480 W7 · form_from any_set (обращение kind_when)', () {
    const section = {
      'detect': {
        'scheme_in': ['plain', 'special']
      },
      'emit': {
        'form': 'url',
        'form_from': {
          'any_set': {
            'special': ['a', 'b'],
            '*': 'plain',
          }
        },
      },
      'params': {
        'server': {'source': 'host', 'maps_to': 'server'},
        'server_port': {'source': 'port', 'maps_to': 'server_port'},
        'a': {'source': 'query.a', 'maps_to': 'a'},
      },
    };

    test('заполнен хоть один путь набора → написание набора', () {
      // Род узла объявлен НАБОРОМ полей, а не одним значением одного пути:
      // обычная ветка form_from его не выразила бы.
      expect(_emit(section, {'server': 'h', 'server_port': 1, 'a': 'v'}),
          'special://h:1?a=v');
    });

    test('ни одного пути набора → ветка «*»', () {
      expect(_emit(section, {'server': 'h', 'server_port': 1}), 'plain://h:1');
    });
  });

  group('§480 W8 · emit.names', () {
    Map<String, dynamic> section(Map<String, dynamic> names) => {
          'emit': {'form': 'url', 'param_order': 'alphabetical', 'names': names},
          'params': {
            'server': {'source': 'host', 'maps_to': 'server'},
            'server_port': {'source': 'port', 'maps_to': 'server_port'},
            'insecure': {
              'source': ['query.insecure', 'query.allowInsecure'],
              'maps_to': 'tls.insecure',
              'type': 'bool_spelled',
            },
          },
        };
    const body = {
      'server': 'h',
      'server_port': 1,
      'tls': {'insecure': true},
    };

    test('написание из source записи — пишется оно', () {
      // Выбор выходного написания принадлежит СХЕМЕ: `allowInsecure` читают
      // все Xray-клиенты, `insecure` читают не все.
      expect(_emit(section({'insecure': 'allowInsecure'}), body),
          'x://h:1?allowInsecure=1');
    });

    test('без объявления — канон записи (первое в aliases)', () {
      expect(_emit(section({}), body), 'x://h:1?insecure=1');
    });

    test('написание, которого запись НЕ читает, отвергается', () {
      // Пиши мы имя вне набора — своя же ссылка обратно не разобралась бы.
      // Эмит молча откатывается к канону, а вслух об этом говорит линтер.
      expect(_emit(section({'insecure': 'skipVerify'}), body),
          'x://h:1?insecure=1');
    });

    test('readableNames — имя, алиасы и query-написания source', () {
      final p = MapperSection.fromJson('uri', 'x', section({}))
          .params['insecure']!;
      expect(readableNames(p), {'insecure', 'allowInsecure'});
    });
  });

  group('§480 · синк 1.1.37 · написание булева объявляет ЗАПИСЬ, не тип', () {
    // Контракт 1.1.36 снял у xhttp-булевых объявление `emit_as: raw`, и
    // соблазн вывести написание из типа (`bool_spelled` → слово) здесь
    // разбирается вслух, потому что он НЕВЕРЕН в обе стороны:
    //
    // - у лаунчера `bool` и `bool_spelled` на выходе неразличимы (exec.go,
    //   одна ветка), а СЛОВОМ он пишет любой необъявленный булев — цифру
    //   даёт только явный `emit_as: bool01`;
    // - у нас умолчание обратное (цифра), и словом пишет только явный
    //   `emit_as: raw`.
    //
    // Привязка к типу сменила бы вид ссылок tuic: `reduce_rtt` объявлен
    // `bool_spelled`, а наши ссылки несут `reduce_rtt=1` с самого начала.
    // Поэтому у xhttp-записей `emit_as: raw` остаётся НАШИМ оверлеем.
    Map<String, dynamic> sectionOf(String type, {String? emitAs}) => {
          'emit': {'form': 'url', 'param_order': 'alphabetical'},
          'params': {
            'server': {'source': 'host', 'maps_to': 'server'},
            'server_port': {'source': 'port', 'maps_to': 'server_port'},
            'flag': {
              'source': 'query.flag',
              'maps_to': 'transport.flag',
              'type': type,
              'emit_as': ?emitAs,
            },
          },
        };
    const body = {
      'server': 'h',
      'server_port': 1,
      'transport': {'flag': true},
    };

    test('bool_spelled БЕЗ объявления — цифра: тип написания не решает', () {
      expect(_emit(sectionOf('bool_spelled'), body), 'x://h:1?flag=1');
    });

    test('bool без объявления — та же цифра', () {
      expect(_emit(sectionOf('bool'), body), 'x://h:1?flag=1');
    });

    test('emit_as: raw — слово, и это ЕДИНСТВЕННЫЙ способ его получить', () {
      expect(_emit(sectionOf('bool_spelled', emitAs: 'raw'), body),
          'x://h:1?flag=true');
      expect(_emit(sectionOf('bool', emitAs: 'raw'), body),
          'x://h:1?flag=true');
    });

    test('ложь не пишется вовсе — ни с объявлением, ни без', () {
      const off = {
        'server': 'h',
        'server_port': 1,
        'transport': {'flag': false},
      };
      expect(_emit(sectionOf('bool_spelled'), off), 'x://h:1');
      expect(_emit(sectionOf('bool_spelled', emitAs: 'raw'), off), 'x://h:1');
    });
  });
}
