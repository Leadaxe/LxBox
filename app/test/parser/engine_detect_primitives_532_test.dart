// §532 — ПРЕДИКАТЫ `detect.json` СВЕДЕНЫ С ЭТАЛОНОМ (Go-исполнение в
// лаунчере, PRIMITIVES FROZEN).
//
// Один реестр обязан исполняться одинаково обеими сторонами: файлы доезжают
// байт в байт, и расхождение живёт не в них, а в движке. Таблица случаев здесь
// ЗЕРКАЛИТ Go — `core/config/linkmap/detect.go` (`matchJSON`, `lookupPath`,
// `jsonTypeOf`) и его тест `linkmap_test.go` «detect различает четыре вида
// источника».
//
// Три дефекта, закрытые этим файлом (ревизия зеркала 24.09.2026, §3 п.1–2):
//
// 1. `json.key_absent` не исполнялся вовсе — неизвестный ключ читался как
//    истина, и ветка «поля версии нет» проходила при ЛЮБОМ содержимом;
// 2. `json.type_of` проходил при ОТСУТСТВУЮЩЕМ пути (Go — нет), из-за чего
//    предикат перестал отличать форму значения от его отсутствия;
// 3. `$root` как путь не разбирался, и предикат о форме документа целиком
//    молча не сходился ни с чем.

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/engine/interpreter.dart';

/// `detect` из JSON-литерала — ровно так его несёт реестр.
bool matches(Map<String, dynamic> detect, dynamic value) =>
    detectMatchesJson(detect, value);

void main() {
  group('§532 п.1 · json.key_absent', () {
    test('путь есть — предикат НЕ сходится', () {
      expect(
        matches(
          {
            'json': {'key_absent': ['type']}
          },
          {'type': 'vless', 'server': 'a.com'},
        ),
        isFalse,
        reason: 'прежде предикат не исполнялся и давал истину при любом входе',
      );
    });

    test('пути нет — предикат сходится', () {
      expect(
        matches(
          {
            'json': {'key_absent': ['type']}
          },
          {'outbounds': <dynamic>[]},
        ),
        isTrue,
      );
    });

    test('НИ ОДНОГО из путей нет — конъюнкция по списку', () {
      const d = {
        'json': {
          'key_absent': ['streamSettings.hysteriaSettings.version', 'settings.version']
        }
      };
      expect(matches(d, {'protocol': 'x'}), isTrue);
      // Достаточно ОДНОГО присутствующего пути, чтобы предикат не сошёлся.
      expect(
        matches(d, {
          'settings': {'version': 1}
        }),
        isFalse,
      );
      expect(
        matches(d, {
          'streamSettings': {
            'hysteriaSettings': {'version': 2}
          }
        }),
        isFalse,
      );
    });

    test('ЧУЖАЯ версия ветку «поля версии нет» не проходит', () {
      // Живой дефект ревизии: элемент с version: 3 уезжал в секцию старшей
      // версии, потому что `key_absent` молчал. Форма предиката — та же, что у
      // реестровой секции (`any` из трёх ветвей), только имена обезличены.
      const branchNoVersion = {
        'json': {
          'key_absent': ['streamSettings.hysteriaSettings.version', 'settings.version']
        }
      };
      final v3 = {
        'protocol': 'hy',
        'settings': {'version': 3}
      };
      expect(matches(branchNoVersion, v3), isFalse);

      // …а ветка «версия РАВНА 1» его тоже не берёт: типы не приводятся.
      const branchV1 = {
        'json': {
          'value_of': {'settings.version': 1}
        }
      };
      expect(matches(branchV1, v3), isFalse);
    });

    test('key_absent под `not` — двойное отрицание, как у Go', () {
      const d = {
        'not': {
          'json': {'key_absent': ['type']}
        }
      };
      expect(matches(d, {'type': 'vless'}), isTrue);
      expect(matches(d, {'outbounds': <dynamic>[]}), isFalse);
    });

    test('вид источника: одиночный outbound vs конфиг (кейс Go)', () {
      // Зеркало `linkmap_test.go`: селектор несёт И `type`, И `outbounds`, и
      // это outbound, а не конфиг — отсекает именно `key_absent`.
      const sbConfig = {
        'json': {
          'any_keys': ['outbounds', 'endpoints'],
          'key_absent': ['type'],
        }
      };
      expect(
        matches(sbConfig, {
          'type': 'selector',
          'outbounds': ['a', 'b']
        }),
        isFalse,
      );
      expect(
        matches(sbConfig, {
          'endpoints': [
            {'type': 'wireguard'}
          ]
        }),
        isTrue,
      );
    });
  });

  group('§532 п.1 · json.any_keys', () {
    test('хотя бы один путь есть', () {
      const d = {
        'json': {
          'any_keys': ['outbounds', 'endpoints']
        }
      };
      expect(matches(d, {'outbounds': <dynamic>[]}), isTrue);
      expect(matches(d, {'endpoints': <dynamic>[]}), isTrue);
      expect(matches(d, {'type': 'vless'}), isFalse);
    });

    test('пустой список условием НЕ является', () {
      expect(
        matches(
          {
            'json': {'any_keys': <String>[]}
          },
          {'whatever': 1},
        ),
        isTrue,
      );
    });
  });

  group('§532 п.2 · json.type_of требует СУЩЕСТВОВАНИЯ пути', () {
    const objectStream = {
      'json': {
        'type_of': {'streamSettings': 'object'}
      }
    };

    test('путь есть и тип совпал — сходится', () {
      expect(
        matches(objectStream, {
          'streamSettings': {'network': 'ws'}
        }),
        isTrue,
      );
    });

    test('путь есть, тип ЧУЖОЙ — не сходится (битая запись)', () {
      expect(matches(objectStream, {'streamSettings': 'none'}), isFalse);
      expect(matches(objectStream, {'streamSettings': <dynamic>[]}), isFalse);
    });

    test('пути НЕТ — не сходится (было: проходило)', () {
      expect(
        matches(objectStream, {'protocol': 'vless'}),
        isFalse,
        reason: 'у отсутствующего значения ответа «что это за тип» нет',
      );
    });

    test('«объект ИЛИ ключа нет» реестр выражает any + key_absent', () {
      // Так объявлены формы xray-секций, у которых контейнер потока законно
      // отсутствует (plain-TCP). Подмена `type_of` на снисходительный делала
      // вторую ветку МЁРТВОЙ — различие выражать было нечем.
      const form = {
        'all': [
          {
            'json': {
              'type_of': {'settings': 'object'}
            }
          },
          {
            'any': [
              {
                'json': {
                  'type_of': {'streamSettings': 'object'}
                }
              },
              {
                'json': {'key_absent': ['streamSettings']}
              },
            ]
          },
        ]
      };
      // plain-TCP: streamSettings нет вовсе — форма опознаётся.
      expect(
        matches(form, {
          'settings': {'vnext': <dynamic>[]}
        }),
        isTrue,
      );
      // транспорт объявлен объектом — опознаётся.
      expect(
        matches(form, {
          'settings': {'vnext': <dynamic>[]},
          'streamSettings': {'network': 'ws'}
        }),
        isTrue,
      );
      // МУСОРНЫЙ ТИП транспорта — форма НЕ опознаётся (битая запись).
      expect(
        matches(form, {
          'settings': {'vnext': <dynamic>[]},
          'streamSettings': 'none'
        }),
        isFalse,
      );
      // контейнер обязан быть объектом всегда: без него нет ни адреса, ни users.
      expect(matches(form, {'settings': <dynamic>[]}), isFalse);
    });

    test('набор имён типов тот же, что у Go, включая bool', () {
      bool isType(String t, dynamic v) => matches(
            {
              'json': {
                'type_of': {'f': t}
              }
            },
            {'f': v},
          );
      expect(isType('object', <String, dynamic>{}), isTrue);
      expect(isType('array', <dynamic>[]), isTrue);
      expect(isType('string', 's'), isTrue);
      expect(isType('number', 1), isTrue);
      expect(isType('number', 1.5), isTrue);
      expect(isType('bool', true), isTrue);
      expect(isType('bool', false), isTrue);
      // Тип не приводится: булев — не число и не строка.
      expect(isType('number', true), isFalse);
      expect(isType('string', 1), isFalse);
    });
  });

  group('§532 п.2 · \$root — САМ документ', () {
    test('форма документа целиком опознаётся', () {
      const arrayDoc = {
        'json': {
          'type_of': {r'$root': 'array'}
        }
      };
      expect(matches(arrayDoc, <dynamic>[]), isTrue);
      expect(matches(arrayDoc, <String, dynamic>{}), isFalse);

      const objectDoc = {
        'json': {
          'type_of': {r'$root': 'object'}
        }
      };
      expect(matches(objectDoc, <String, dynamic>{}), isTrue);
      expect(matches(objectDoc, <dynamic>[]), isFalse);
      // Строка (cleartext) — не объект: именно это различие \$root и несёт.
      expect(matches(objectDoc, 'ss://…'), isFalse);
    });

    test('jsonPathValue отдаёт корень как значение', () {
      expect(jsonPathValue(<dynamic>[1, 2], r'$root'), <dynamic>[1, 2]);
      expect(jsonPathValue({'a': 1}, r'$root'), {'a': 1});
    });
  });

  group('§532 · вид источника целиком (таблица Go)', () {
    // Зеркало `linkmap_test.go`: те же предикаты, те же тела, тот же вывод.
    const xray = {
      'json': {
        'type_of': {'outbounds': 'array'},
        'array_elem_any_keys': ['outbounds[].protocol'],
      }
    };
    const sbOutbound = {
      'json': {'required_keys': ['type']}
    };
    const sbConfig = {
      'json': {
        'any_keys': ['outbounds', 'endpoints'],
        'key_absent': ['type'],
      }
    };

    test('xray-конфиг', () {
      final doc = {
        'outbounds': [
          {'protocol': 'vless', 'settings': <String, dynamic>{}}
        ]
      };
      expect(matches(xray, doc), isTrue);
      expect(matches(sbOutbound, doc), isFalse);
    });

    test('одиночный sing-box outbound', () {
      final doc = {'type': 'vless', 'server': 'a.com', 'server_port': 443};
      expect(matches(sbOutbound, doc), isTrue);
      expect(matches(xray, doc), isFalse);
      expect(matches(sbConfig, doc), isFalse);
    });

    test('sing-box конфиг с endpoints', () {
      final doc = {
        'endpoints': [
          {'type': 'wireguard'}
        ]
      };
      expect(matches(sbConfig, doc), isTrue);
      expect(matches(sbOutbound, doc), isFalse);
      expect(matches(xray, doc), isFalse);
    });
  });
}
