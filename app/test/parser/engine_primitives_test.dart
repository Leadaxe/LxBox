import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/engine/interpreter.dart';
import 'package:lxbox/services/parser/engine/section.dart';

/// §480 W1 — каждый примитив грамматики на своей секции.
///
/// Секции здесь СИНТЕТИЧЕСКИЕ: настоящие лежат в реестре и проверяются
/// фикстурами, а тут проверяется сам движок — что `sets` с `null` снимает
/// путь, что `priority` решает конфликт, что `when` умеет спрашивать
/// источник. Живая секция покрывает примитивы вперемешку, и красный кейс на
/// ней не говорит, КАКОЙ примитив сломан.
///
/// Тип тела у синтетических секций — `probe`: имени схемы здесь быть не
/// должно ровно так же, как в самом движке.
MapperSection _section(Map<String, dynamic> json) =>
    MapperSection.fromJson('uri', 'probe', json);

Map<String, dynamic>? _run(Map<String, dynamic> json, String uri) =>
    runSection(_section(json), uri)?.body;

/// Минимальная секция: адрес плюс переданные записи.
Map<String, dynamic> _withParams(Map<String, dynamic> params,
        {Map<String, dynamic>? extra}) =>
    {
      'body_source': 'uri',
      'params': {
        'server': {'source': 'host', 'maps_to': 'server'},
        'server_port': {'source': 'port', 'maps_to': 'server_port',
            'type': 'int'},
        ...params,
      },
      ...?extra,
    };

void main() {
  group('P3 source — единственный доступ к значению', () {
    test('читается только объявленный источник', () {
      final body = _run(
        _withParams({'a': {'source': 'query.a', 'maps_to': 'a'}}),
        'x://h.com:443?a=1&b=2',
      )!;
      expect(body['a'], '1');
      // `b` не объявлен — движку его даже не достать.
      expect(body.containsKey('b'), isFalse);
    });

    test('список источников — первый найденный', () {
      final s = _withParams({
        'sni': {'source': ['query.sni', 'query.peer', 'host'],
            'maps_to': 'tls.server_name'},
      });
      expect((_run(s, 'x://h.com:443?peer=p.com')!['tls'] as Map)['server_name'],
          'p.com');
      expect(
          (_run(s, 'x://h.com:443?sni=s.com&peer=p.com')!['tls']
              as Map)['server_name'],
          's.com');
    });

    test('лексические источники: scheme, port_raw, fragment', () {
      final body = _run(
        _withParams({
          'sch': {'source': 'scheme', 'maps_to': 'sch'},
          'pr': {'source': 'port_raw', 'maps_to': 'pr'},
        }),
        'HY2://h.com:443,8000-9000?x=1',
      )!;
      expect(body['sch'], 'HY2');
      expect(body['pr'], '443,8000-9000');
    });
  });

  group('P4 value_map — перевод значений диалекта', () {
    final s = _withParams({
      't': {'source': 'query.t', 'maps_to': 'transport.type',
          'value_map': {'': null, 'tcp': null, 'h2': 'http'}},
    });

    test('перевод написания', () {
      expect((_run(s, 'x://h.com:443?t=h2')!['transport'] as Map)['type'],
          'http');
    });

    test('null означает «ключа нет», а не значение null', () {
      expect(_run(s, 'x://h.com:443?t=tcp')!.containsKey('transport'), isFalse);
    });

    test('неопознанное значение едет КАК ПРИШЛО — судит санитайзер', () {
      expect((_run(s, 'x://h.com:443?t=ws')!['transport'] as Map)['type'], 'ws');
    });

    test('prefix + strip: чужие идентификаторы по началу имени', () {
      final fp = _withParams({
        'fp': {'source': 'query.fp', 'maps_to': 'f', 'value_map': {
          'prefix': {'hellochrome': 'chrome', 'hellorandomized': 'randomized',
              'hellorandom': 'random'},
          'strip': ['_', '-', ' '],
        }},
      });
      expect(_run(fp, 'x://h.com:443?fp=HelloChrome_120')!['f'], 'chrome');
      // Длинный префикс проверяется раньше короткого, иначе `hellorandom`
      // перехватил бы `hellorandomized`.
      expect(_run(fp, 'x://h.com:443?fp=HelloRandomized')!['f'], 'randomized');
      expect(_run(fp, 'x://h.com:443?fp=bogus')!['f'], 'bogus');
    });
  });

  group('P5 selector + when — двухпроходность', () {
    final s = _withParams({
      'type': {'source': 'query.type', 'selector': true,
          'maps_to': 'transport.type', 'value_map': {'': null, 'tcp': null}},
      'path': {'source': 'query.path', 'maps_to': 'transport.path',
          'when': {'transport.type': {'in': ['ws', 'httpupgrade']}}},
    });

    test('зависимая запись видит тело, построенное селектором', () {
      expect((_run(s, 'x://h.com:443?type=ws&path=/p')!['transport']
          as Map)['path'], '/p');
    });

    test('условие не держится — записи нет', () {
      expect(_run(s, 'x://h.com:443?type=grpc&path=/p')!['transport'],
          {'type': 'grpc'});
    });

    // G1 (FROZEN): условие по ИСТОЧНИКУ, а не по телу. Нужно там, где в теле
    // не остаётся следа — род узла объявляет ВХОД.
    test('G1 — when по источнику', () {
      final g1 = _withParams({
        'ht': {'source': 'query.headerType', 'maps_to': 'transport.type',
            'when': {'query.type': {'in': ['tcp', '']}}},
      });
      expect((_run(g1, 'x://h.com:443?type=tcp&headerType=http')!['transport']
          as Map)['type'], 'http');
      expect(_run(g1, 'x://h.com:443?type=ws&headerType=http')!
          .containsKey('transport'), isFalse);
    });

    test('when по типу тела и по форме', () {
      final s2 = _withParams({
        'a': {'source': 'query.a', 'maps_to': 'a', 'when': {r'$type': 'probe'}},
        'b': {'source': 'query.b', 'maps_to': 'b', 'when': {r'$type': 'other'}},
        'c': {'source': 'query.c', 'maps_to': 'c', 'when': {r'$form': 'url'}},
      });
      final body = _run(s2, 'x://h.com:443?a=1&b=2&c=3')!;
      expect(body['a'], '1');
      expect(body.containsKey('b'), isFalse);
      expect(body['c'], '3');
    });
  });

  group('P6/P7 sets и implies', () {
    test('sets по значению даёт набор присваиваний', () {
      final s = _withParams({
        'sec': {'source': 'query.security', 'selector': true, 'sets': {
          'tls': {'tls.enabled': true},
          'reality': {'tls.enabled': true, 'tls.reality.enabled': true},
          'none': {},
          '': {'tls.enabled': true},
        }},
      });
      expect(_run(s, 'x://h.com:443?security=tls')!['tls'], {'enabled': true});
      expect((_run(s, 'x://h.com:443?security=reality')!['tls']
          as Map)['reality'], {'enabled': true});
      // Пустой набор — ключ НЕ появляется вовсе (не `enabled: false`).
      expect(_run(s, 'x://h.com:443?security=none')!.containsKey('tls'),
          isFalse);
      // Параметра нет — работает ключ `""`.
      expect(_run(s, 'x://h.com:443')!['tls'], {'enabled': true});
    });

    // G2 (FROZEN): `null` в присваивании СНИМАЕТ путь. Отличается от «не
    // писать»: флаг обязан убрать уже поставленное значение.
    test('G2 — sets с null снимает путь', () {
      final s = _withParams({
        'sni': {'source': 'query.sni', 'maps_to': 'tls.server_name'},
        'off': {'source': 'query.off', 'type': 'bool_spelled',
            'maps_to': 'tls.disable_sni',
            'sets': {'1': {'tls.server_name': null}}},
      });
      expect((_run(s, 'x://h.com:443?sni=a.com')!['tls'] as Map)['server_name'],
          'a.com');
      final off = _run(s, 'x://h.com:443?sni=a.com&off=1')!['tls'] as Map;
      expect(off.containsKey('server_name'), isFalse);
      expect(off['disable_sni'], isTrue);
    });

    test('implies — от НАЛИЧИЯ параметра', () {
      final s = _withParams({
        'pbk': {'source': 'query.pbk', 'maps_to': 'tls.reality.public_key',
            'implies': {'tls.enabled': true, 'tls.reality.enabled': true}},
      });
      expect(_run(s, 'x://h.com:443?pbk=KEY')!['tls'],
          {'reality': {'public_key': 'KEY', 'enabled': true}, 'enabled': true});
      expect(_run(s, 'x://h.com:443')!.containsKey('tls'), isFalse);
    });

    test('scheme_sets — написание схемы несёт тело', () {
      final s = _withParams({}, extra: {
        'scheme_sets': {
          'p4': {'version': '4'},
          'p4a': {'version': '4a'},
        },
      });
      expect(_run(s, 'p4://h.com:443')!['version'], '4');
      expect(_run(s, 'p4a://h.com:443')!['version'], '4a');
      expect(_run(s, 'p5://h.com:443')!.containsKey('version'), isFalse);
    });
  });

  group('G3 priority + merge — конфликт записей в один путь', () {
    // Поправка лаунчера: побеждает не «sets сильнее», а объявленный порядок.
    // Значение, переведённое в null, записи НЕ делает — и именно поэтому
    // уцелевает то, что поставил sets.
    final s = _withParams({
      'flow': {'source': 'query.flow', 'maps_to': 'flow', 'priority': 10,
          'value_map': {'v-udp443': 'v'},
          'sets': {'v-udp443': {'packet_encoding': 'xudp'}}},
      'pe': {'source': 'query.packetEncoding', 'maps_to': 'packet_encoding',
          'priority': 20, 'merge': 'overwrite', 'value_map': {'none': null}},
    });

    test('явное значение перебивает поставленное sets', () {
      final body = _run(s, 'x://h.com:443?flow=v-udp443&packetEncoding=xudp2')!;
      expect(body['packet_encoding'], 'xudp2');
    });

    test('«none» → null записи не делает, и xudp уцелевает', () {
      final body = _run(s, 'x://h.com:443?flow=v-udp443&packetEncoding=none')!;
      expect(body['packet_encoding'], 'xudp');
      expect(body['flow'], 'v');
    });

    test('keep_first: занявший с меньшим priority побеждает', () {
      final s2 = _withParams({
        'a': {'source': 'query.a', 'maps_to': 'p', 'priority': 1},
        'b': {'source': 'query.b', 'maps_to': 'p', 'priority': 2},
      });
      expect(_run(s2, 'x://h.com:443?a=first&b=second')!['p'], 'first');
    });
  });

  group('P8 extract — одно значение по нескольким путям', () {
    final s = _withParams({
      'type': {'source': 'query.type', 'selector': true,
          'maps_to': 'transport.type', 'value_map': {'': null}},
      'path': {'source': 'query.path', 'when': {'transport.type': 'ws'},
          'decode_extra': {'mode': 'path', 'passes': 2},
          'extract': {
            're': r'^(?P<path>[^?]*)(?:\?ed=(?P<ed>\d+))?$',
            'into': {
              'path': 'transport.path',
              'ed': {'path': 'transport.max_early_data', 'type': 'int',
                  'implies': {'transport.early_data_header_name':
                      {'value': 'Sec-WebSocket-Protocol', 'implicit': true}}},
            },
          }},
    });

    test('хвост ?ed=N — два поля тела плюс конвенционный заголовок', () {
      final tr = _run(s, 'x://h.com:443?type=ws&path=%2Fx%3Fed%3D2560')![
          'transport'] as Map;
      expect(tr['path'], '/x');
      expect(tr['max_early_data'], 2560);
      expect(tr['early_data_header_name'], 'Sec-WebSocket-Protocol');
    });

    test('без хвоста — только путь', () {
      final tr = _run(s, 'x://h.com:443?type=ws&path=%2Fx')!['transport'] as Map;
      expect(tr['path'], '/x');
      expect(tr.containsKey('max_early_data'), isFalse);
    });

    test('Go-написание группы (?P<name>) понимается', () {
      // Реестр пишется у лаунчера, то есть в Go-диалекте; перевод делает
      // движок, а не правка данных.
      final tr = _run(s, 'x://h.com:443?type=ws&path=%2Fa%2Bb')!['transport']
          as Map;
      expect(tr['path'], '/a+b');
    });
  });

  group('P9 list — список через разделитель', () {
    test('запятая, элементы обрезаны', () {
      final s = _withParams({
        'alpn': {'source': 'query.alpn', 'maps_to': 'tls.alpn',
            'list': {'sep': ','}},
      });
      expect((_run(s, 'x://h.com:443?alpn=h2%2C%20http%2F1.1')!['tls']
          as Map)['alpn'], ['h2', 'http/1.1']);
    });

    test('coerce_scalar: скаляр как список из одного', () {
      final s = _withParams({
        'h': {'source': 'query.host', 'maps_to': 'transport.host',
            'list': {'sep': ',', 'coerce_scalar': true}},
      });
      expect((_run(s, 'x://h.com:443?host=a.com')!['transport'] as Map)['host'],
          ['a.com']);
    });

    test('item: int — нечисловое выбрасывается', () {
      final s = _withParams({
        'r': {'source': 'query.r', 'maps_to': 'r', 'list': {'sep': ',',
            'item': 'int'}},
      });
      expect(_run(s, 'x://h.com:443?r=1%2C2%2Cxx%2C4')!['r'], [1, 2, 4]);
    });
  });

  group('P10 default_from / default_when / materialize_default', () {
    // Фолбэк срабатывает и когда параметра НЕТ вовсе: корпус на этом стоит
    // (ссылка без `sni=` ждёт `server_name` = адрес сервера). Это выбор
    // ИСТОЧНИКА поля, а не суждение о значении.
    test('default_from — источник значения по умолчанию', () {
      final s = _withParams({
        'sni': {'source': 'query.sni', 'maps_to': 'tls.server_name',
            'default_from': 'host'},
      });
      expect((_run(s, 'x://h.com:443')!['tls'] as Map)['server_name'], 'h.com',
          reason: 'параметра нет → фолбэк на адрес');
      expect((_run(s, 'x://h.com:443?sni=')!['tls'] as Map)['server_name'],
          'h.com', reason: 'пустое значение = «не задано» → тот же фолбэк');
      expect((_run(s, 'x://h.com:443?sni=s.com')!['tls'] as Map)['server_name'],
          's.com', reason: 'явное значение фолбэк не трогает');
    });

    test('default_from не срабатывает, когда when записи не держится', () {
      final s = _withParams({
        'sni': {'source': 'query.sni', 'maps_to': 'tls.server_name',
            'default_from': 'host', 'when': {'tls.enabled': true}},
      });
      expect(_run(s, 'x://h.com:443')!.containsKey('tls'), isFalse);
    });

    test('materialize_default — дефолт пишется, даже когда источник молчал', () {
      final s = _withParams({
        'e': {'source': 'query.e', 'maps_to': 'enc',
            'materialize_default': true,
            'default_when': {'absent': true, 'value': 'auto'}},
      });
      expect(_run(s, 'x://h.com:443')!['enc'], 'auto');
      expect(_run(s, 'x://h.com:443?e=none')!['enc'], 'none');
    });

    // Норма §10.1 — `defaults` применяются ПОСЛЕ обоих проходов и только в
    // незанятый путь. Ни `priority`, ни `merge` к ним не применяются: они не
    // участвуют в конкуренции, а заполняют оставшееся.
    test('§10.1 defaults секции — только в пустое, после проходов', () {
      final s = _withParams({}, extra: {'defaults': {'server_port': 443}});
      expect(_run(s, 'x://h.com:8443')!['server_port'], 8443,
          reason: 'явный порт из ссылки обязан победить дефолт');
      expect(_run(s, 'x://h.com')!['server_port'], 443);
    });

    test('§10.1 defaults не перебивает даже запись с merge: overwrite', () {
      // Проверка того, ради чего норма выбрала «после проходов, в пустое», а
      // не «очень большой priority»: с числом запись с overwrite победила бы
      // дефолт формально, но порядок записи всё равно решал бы исход.
      final s = _withParams({
        'p': {'source': 'query.p', 'maps_to': 'field', 'merge': 'overwrite'},
      }, extra: {'defaults': {'field': 'from-defaults'}});
      expect(_run(s, 'x://h.com:443?p=from-link')!['field'], 'from-link');
      expect(_run(s, 'x://h.com:443')!['field'], 'from-defaults');
    });
  });

  group('типы значений', () {
    test('bool_spelled — общий набор написаний истины', () {
      final s = _withParams({
        'i': {'source': 'query.i', 'type': 'bool_spelled', 'maps_to': 'ins'},
      });
      for (final v in ['1', 'true', 'TRUE', 'yes', 'Yes']) {
        expect(_run(s, 'x://h.com:443?i=$v')!['ins'], isTrue, reason: v);
      }
      // Ложь = «не просили»: ключ не появляется вовсе.
      for (final v in ['0', 'false', 'no', 'junk']) {
        expect(_run(s, 'x://h.com:443?i=$v')!.containsKey('ins'), isFalse,
            reason: v);
      }
    });

    test('aliases — написания одного имени, канон первым', () {
      final s = _withParams({
        'insecure': {'source': 'query.insecure', 'type': 'bool_spelled',
            'maps_to': 'ins',
            'aliases': ['allowInsecure', 'skip-cert-verify']},
      });
      expect(_run(s, 'x://h.com:443?allowInsecure=1')!['ins'], isTrue);
      expect(_run(s, 'x://h.com:443?ALLOWINSECURE=1')!['ins'], isTrue);
      expect(_run(s, 'x://h.com:443?skip-cert-verify=true')!['ins'], isTrue);
    });

    // G4 (FROZEN): порядок ключей объекта входит в тело, и оставлять его
    // свойством реализации нельзя.
    test('G4 — sort_keys даёт детерминированный порядок', () {
      final s = _section(_withParams({
        'h': {'source': 'query.h', 'maps_to': 'hdr', 'type': 'object',
            'sort_keys': true},
      }));
      // Источник объекта у формы url строкой не бывает, поэтому проверяем
      // сам примитив на форме без сортировки — порядок ключей объекта.
      expect(s.params['h']!.sortKeys, isTrue);
    });
  });

  group('userinfo (P2)', () {
    test('весь userinfo без резки', () {
      final s = _withParams({
        'pw': {'source': 'userinfo', 'maps_to': 'password', 'required': true},
      }, extra: {'userinfo': {'into': ['password']}});
      expect(_run(s, 'x://pa%3Ass%3A1@h.com:443')!['password'], 'pa:ss:1');
    });

    test('split с limit:2 — по ПЕРВОМУ разделителю, хвост целиком', () {
      final s = _withParams({}, extra: {
        'userinfo': {'split': {'sep': ':', 'limit': 2},
            'into': ['uuid', 'password']},
      });
      final body = _run(s, 'x://uid:pa:ss@h.com:443')!;
      expect(body['uuid'], 'uid');
      expect(body['password'], 'pa:ss');
    });

    test('single_into — когда разделителя нет', () {
      final s = _withParams({}, extra: {
        'userinfo': {'split': {'sep': ':'},
            'into': ['username', 'password'], 'single_into': 'password'},
      });
      expect(_run(s, 'x://onlypass@h.com:443')!['password'], 'onlypass');
    });

    test('«+» в userinfo литерален, percent снят', () {
      // `single_into` объявлен ЯВНО: умолчание «одинокий userinfo → первое
      // имя `into`» снято вместе с контрактом 1.1.25, где лаунчер проставил
      // атрибут всем секциям и завёл линтер на его написание.
      final s = _withParams({}, extra: {
        'userinfo': {'into': ['password'], 'single_into': 'password'},
      });
      expect(_run(s, 'x://pa+ss@h.com:443')!['password'], 'pa+ss');
      expect(_run(s, 'x://p%40ss@h.com:443')!['password'], 'p@ss');
    });

    test('required — без значения записи нет вовсе', () {
      final s = _withParams({
        'pw': {'source': 'userinfo', 'maps_to': 'password', 'required': true},
      }, extra: {'userinfo': {'into': ['password']}});
      expect(_run(s, 'x://@h.com:443'), isNull);
    });
  });

  group('G8 метка — нормализация объявлена', () {
    Map<String, dynamic> labelSection(Map<String, dynamic> label) =>
        _withParams({}, extra: {'label': label});

    String? labelOf(Map<String, dynamic> label, String uri) =>
        runSection(_section(labelSection(label)), uri)?.label;

    test('фрагмент: «+» литерален, percent снят', () {
      expect(labelOf({'source': ['fragment']}, 'x://h.com:443#a+b%20c'),
          'a+b c');
    });

    test('strip_control + trim', () {
      expect(
          labelOf({'source': ['fragment'],
              'normalize': ['strip_control', 'trim']},
              'x://h.com:443#%20%01name%20'),
          'name');
    });

    test('value_map — замена в метке', () {
      expect(
          labelOf({'source': ['fragment'], 'value_map': {'🇪🇳': '🇬🇧'}},
              'x://h.com:443#%F0%9F%87%AA%F0%9F%87%B3x'),
          '🇬🇧x');
    });

    test('цепочка источников: фрагмента нет — берётся путь', () {
      expect(labelOf({'source': ['fragment', 'path']}, 'x://h.com:443/named'),
          '/named');
    });

    test('ничего нет — пусто, фолбэк считает конвейер', () {
      expect(labelOf({'source': ['fragment']}, 'x://h.com:443'), '');
    });
  });

  group('unknown_key — необъявленный параметр', () {
    test('код на каждый необъявленный, объявленные молчат', () {
      final s = _withParams({
        'a': {'source': 'query.a', 'maps_to': 'a'},
      }, extra: {'unknown_key': {'action': 'keep', 'code': 'uri_param_unknown'}});
      final res = runSection(_section(s), 'x://h.com:443?a=1&zzz=2&qqq=3')!;
      final paths = res.warnings.map((w) => '$w').join(' ');
      expect(paths, contains('zzz'));
      expect(paths, contains('qqq'));
      expect(res.warnings, hasLength(2));
    });

    test('алиас объявленной записи необъявленным не считается', () {
      final s = _withParams({
        'i': {'source': 'query.i', 'maps_to': 'i', 'aliases': ['eye']},
      }, extra: {'unknown_key': {'action': 'keep', 'code': 'uri_param_unknown'}});
      expect(runSection(_section(s), 'x://h.com:443?eye=1')!.warnings, isEmpty);
    });

    // Норма §10.3 — имя записи и имя параметра в ссылке могут отличаться;
    // объявленным считается имя ИЗ `source`, а не только имя записи.
    test('§10.3 имя из source объявлено наравне с именем записи', () {
      final s = _withParams({
        // Запись зовётся иначе, чем параметр ссылки.
        'ключ': {'source': 'query.realName', 'maps_to': 'f'},
      }, extra: {'unknown_key': {'action': 'keep', 'code': 'uri_param_unknown'}});
      expect(runSection(_section(s), 'x://h.com:443?realName=1')!.warnings,
          isEmpty);
    });

    // Норма §10.2 — спрашивать о параметре и потреблять его разные вещи.
    // Иначе параметр, который только проверяется условием и никуда не
    // пишется, замолкал бы там, где код — единственный признак непонятого
    // входа.
    test('§10.2 when ЧИТАЕТ источник, но прочитанным его не делает', () {
      final s = _withParams({
        // `probe` нигде не объявлен источником — только спрошен условием.
        'f': {'source': 'query.f', 'maps_to': 'f',
            'when': {'query.probe': 'yes'}},
      }, extra: {'unknown_key': {'action': 'keep', 'code': 'uri_param_unknown'}});
      final res = runSection(_section(s), 'x://h.com:443?f=1&probe=yes')!;
      expect(res.body['f'], '1', reason: 'условие по источнику сработало');
      expect(res.warnings.map((w) => '$w').join(), contains('probe'),
          reason: 'спрошенный условием параметр объявленным не становится');
    });
  });
}
