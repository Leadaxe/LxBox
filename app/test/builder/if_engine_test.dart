import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/if_engine.dart';

/// §120 — typed template engine + `#if`. Unit-тесты ядра [if_engine].

VarResolver _resolver(Map<String, String> vars, Map<String, String> types) {
  final nodes = <String, WizardVar>{
    for (final e in types.entries)
      e.key: WizardVar(name: e.key, type: e.value, defaultValue: ''),
  };
  return makeResolver(vars, nodes);
}

void main() {
  group('Часть 1 — coerceVarValue', () {
    test('bool: true/false строго', () {
      expect(coerceVarValue('true', 'bool'), true);
      expect(coerceVarValue('false', 'bool'), false);
      expect(coerceVarValue('yes', 'bool'), false); // прочее → false
    });

    test('int: число → int, не-число → строка', () {
      expect(coerceVarValue('1492', 'int'), 1492);
      expect(coerceVarValue('1492', 'int'), isA<int>());
      expect(coerceVarValue('abc', 'int'), 'abc');
    });

    test('int: clamp в uint16 [0, 65535] (§161 backstop)', () {
      expect(coerceVarValue('65535', 'int'), 65535); // граница
      expect(coerceVarValue('65536', 'int'), 65535); // выше → clamp
      expect(coerceVarValue('99999', 'int'), 65535);
      expect(coerceVarValue('-5', 'int'), 0); // ниже → clamp
      expect(coerceVarValue('30', 'int'), 30); // в диапазоне — без изменений
    });

    test('secret/text: НЕ коэрсятся даже если выглядят как число/bool', () {
      expect(coerceVarValue('1234', 'secret'), '1234');
      expect(coerceVarValue('1234', 'secret'), isA<String>());
      expect(coerceVarValue('true', 'text'), 'true');
      expect(coerceVarValue('007', 'text'), '007'); // ноль не теряется
    });

    test('enum/outbound/dns_servers/unknown → строка', () {
      expect(coerceVarValue('mixed', 'enum'), 'mixed');
      expect(coerceVarValue('direct-out', 'outbound'), 'direct-out');
      expect(coerceVarValue('123', 'whatever'), '123');
    });
  });

  group('Часть 1 — walk var substitution', () {
    test('@var коэрсится по node.type', () {
      final node = <String, dynamic>{
        'port': '@p',
        'name': '@n',
        'on': '@b',
      };
      walk(
          node,
          _resolver(
            {'p': '8080', 'n': '8080', 'b': 'true'},
            {'p': 'int', 'n': 'text', 'b': 'bool'},
          ));
      expect(node['port'], 8080);
      expect(node['name'], '8080'); // text — строка
      expect(node['on'], true);
    });

    test('var без ноды → coerce как text (строка)', () {
      final node = <String, dynamic>{'x': '@legacy'};
      walk(node, makeResolver({'legacy': '999'}, {}));
      expect(node['x'], '999');
      expect(node['x'], isA<String>());
    });

    test('неизвестное @имя → плейсхолдер остаётся', () {
      final node = <String, dynamic>{'x': '@missing'};
      walk(node, makeResolver({}, {}));
      expect(node['x'], '@missing');
    });
  });

  group('Часть 2 — #if map-spread', () {
    test('and-true → поля value мерджатся', () {
      final node = <String, dynamic>{
        'tag': 'x',
        '#if': {
          'and': ['@auth'],
          'value': {'users': 'present'},
        },
      };
      walk(node, _resolver({'auth': 'true'}, {'auth': 'bool'}));
      expect(node['tag'], 'x');
      expect(node['users'], 'present');
      expect(node.containsKey('#if'), false);
    });

    test('and-false без else → ключ #if снят, parent unchanged', () {
      final node = <String, dynamic>{
        'tag': 'x',
        '#if': {
          'and': ['@auth'],
          'value': {'users': 'present'},
        },
      };
      walk(node, _resolver({'auth': 'false'}, {'auth': 'bool'}));
      expect(node['tag'], 'x');
      expect(node.containsKey('users'), false);
      expect(node.containsKey('#if'), false);
    });

    test('and-false с else → поля else мерджатся', () {
      final node = <String, dynamic>{
        '#if': {
          'and': ['@auth'],
          'value': {'a': 1},
          'else': {'b': 2},
        },
      };
      walk(node, _resolver({'auth': 'false'}, {'auth': 'bool'}));
      expect(node['b'], 2);
      expect(node.containsKey('a'), false);
    });
  });

  group('Часть 2 — #if array-element', () {
    test('true → элемент заменяется на value', () {
      final list = <dynamic>[
        {
          '#if': {
            'and': ['@x'],
            'value': 'kept',
          },
        },
      ];
      walk(list, _resolver({'x': 'true'}, {'x': 'bool'}));
      expect(list, ['kept']);
    });

    test('false без else → элемент выпадает (len-1)', () {
      final list = <dynamic>[
        'a',
        {
          '#if': {
            'and': ['@x'],
            'value': 'dropped',
          },
        },
        'c',
      ];
      walk(list, _resolver({'x': 'false'}, {'x': 'bool'}));
      expect(list, ['a', 'c']);
    });

    test('false с else → элемент = else', () {
      final list = <dynamic>[
        {
          '#if': {
            'and': ['@x'],
            'value': 'v',
            'else': 'e',
          },
        },
      ];
      walk(list, _resolver({'x': 'false'}, {'x': 'bool'}));
      expect(list, ['e']);
    });
  });

  group('Часть 2 — predicates', () {
    Map<String, dynamic> evalGate(dynamic predicate, Map<String, String> vars,
        Map<String, String> types) {
      final node = <String, dynamic>{
        '#if': {
          'and': [predicate],
          'value': {'hit': true},
        },
      };
      walk(node, _resolver(vars, types));
      return node;
    }

    test('equality {@v: literal}', () {
      expect(
          evalGate({'@m': 'proxy'}, {'m': 'proxy'}, {'m': 'enum'})['hit'], true);
      expect(evalGate({'@m': 'proxy'}, {'m': 'vpn'}, {'m': 'enum'})
          .containsKey('hit'), false);
    });

    test('#in', () {
      expect(
          evalGate({
            '@m': {
              '#in': ['vpn', 'vpn_proxy'],
            }
          }, {'m': 'vpn_proxy'}, {'m': 'enum'})['hit'],
          true);
      expect(
          evalGate({
            '@m': {
              '#in': ['vpn'],
            }
          }, {'m': 'proxy'}, {'m': 'enum'}).containsKey('hit'),
          false);
    });

    test('#notIn', () {
      expect(
          evalGate({
            '@m': {
              '#notIn': ['vpn'],
            }
          }, {'m': 'proxy'}, {'m': 'enum'})['hit'],
          true);
    });

    test('#notEmpty / #isEmpty', () {
      expect(evalGate({'@p': '#notEmpty'}, {'p': 'x'}, {'p': 'secret'})['hit'],
          true);
      expect(
          evalGate({'@p': '#notEmpty'}, {'p': ''}, {'p': 'secret'})
              .containsKey('hit'),
          false);
      expect(evalGate({'@p': '#isEmpty'}, {'p': ''}, {'p': 'secret'})['hit'],
          true);
    });

    test('#matches', () {
      expect(
          evalGate({
            '@h': {'#matches': r'^test-'}
          }, {'h': 'test-node'}, {'h': 'text'})['hit'],
          true);
      expect(
          evalGate({
            '@h': {'#matches': r'^test-'}
          }, {'h': 'prod'}, {'h': 'text'}).containsKey('hit'),
          false);
    });

    test('bare bool var', () {
      expect(evalGate('@on', {'on': 'true'}, {'on': 'bool'})['hit'], true);
      expect(
          evalGate('@on', {'on': 'false'}, {'on': 'bool'}).containsKey('hit'),
          false);
    });

    test('#not негация + двойная негация', () {
      expect(
          evalGate({
            '#not': '@on'
          }, {'on': 'false'}, {'on': 'bool'})['hit'],
          true);
      expect(
          evalGate({
            '#not': {'#not': '@on'}
          }, {'on': 'true'}, {'on': 'bool'})['hit'],
          true);
    });

    test('or — хотя бы один true', () {
      final node = <String, dynamic>{
        '#if': {
          'or': [
            {'@m': 'proxy'},
            {'@m': 'vpn_proxy'},
          ],
          'value': {'hit': true},
        },
      };
      walk(node, _resolver({'m': 'vpn_proxy'}, {'m': 'enum'}));
      expect(node['hit'], true);
    });
  });

  group('Часть 2 — вложенный #if (top-down lazy)', () {
    test('outer-true → внутренний #if в value резолвится', () {
      final node = <String, dynamic>{
        '#if': {
          'and': ['@outer'],
          'value': {
            'a': 1,
            '#if': {
              'and': ['@inner'],
              'value': {'b': 2},
            },
          },
        },
      };
      walk(node, _resolver({'outer': 'true', 'inner': 'true'},
          {'outer': 'bool', 'inner': 'bool'}));
      expect(node['a'], 1);
      expect(node['b'], 2);
    });

    test('outer-false → внутренний #if в отброшенной ветке НЕ влияет', () {
      final node = <String, dynamic>{
        'keep': 'me',
        '#if': {
          'and': ['@outer'],
          'value': {
            '#if': {
              'and': ['@inner'],
              'value': {'b': 2},
            },
          },
        },
      };
      walk(node, _resolver({'outer': 'false', 'inner': 'true'},
          {'outer': 'bool', 'inner': 'bool'}));
      expect(node['keep'], 'me');
      expect(node.containsKey('b'), false);
    });
  });

  group('Часть 2 — unknown #*-сиблинг forward-compat', () {
    test('unknown #*-ключ-сиблинг → drop, остальное цело', () {
      final node = <String, dynamic>{
        'tag': 'x',
        '#frobnicate': 'whatever',
      };
      walk(node, makeResolver({}, {}));
      expect(node['tag'], 'x');
      expect(node.containsKey('#frobnicate'), false);
    });
  });

  group('Template-load валидация #if', () {
    final nodes = <String, WizardVar>{
      'm': WizardVar(name: 'm', type: 'enum', defaultValue: 'vpn'),
      'b': WizardVar(name: 'b', type: 'bool', defaultValue: 'false'),
      't': WizardVar(name: 't', type: 'text', defaultValue: ''),
    };

    void validate(dynamic config) => validateIfConstructs(config, nodes);

    test('валидный #if проходит', () {
      validate({
        'x': [
          {
            '#if': {
              'and': [
                {
                  '@m': {
                    '#in': ['vpn'],
                  }
                },
                '@b',
                {'#not': '@b'},
                {'@t': '#notEmpty'},
              ],
              'value': 'ok',
            },
          },
        ],
      });
    });

    test('оба and+or → error', () {
      expect(
          () => validate({
                '#if': {
                  'and': ['@b'],
                  'or': ['@b'],
                  'value': 1,
                },
              }),
          throwsA(isA<TemplateIfError>()));
    });

    test('ни and ни or → error', () {
      expect(
          () => validate({
                '#if': {'value': 1},
              }),
          throwsA(isA<TemplateIfError>()));
    });

    test('пустой and → error', () {
      expect(
          () => validate({
                '#if': {'and': [], 'value': 1},
              }),
          throwsA(isA<TemplateIfError>()));
    });

    test('нет value → error', () {
      expect(
          () => validate({
                '#if': {
                  'and': ['@b'],
                },
              }),
          throwsA(isA<TemplateIfError>()));
    });

    test('неизвестный inner-ключ (xor) → error', () {
      expect(
          () => validate({
                '#if': {
                  'and': ['@b'],
                  'value': 1,
                  'xor': ['@b'],
                },
              }),
          throwsA(isA<TemplateIfError>()));
    });

    test('предикат на необъявленную var → error', () {
      expect(
          () => validate({
                '#if': {
                  'and': ['@nonexistent'],
                  'value': 1,
                },
              }),
          throwsA(isA<TemplateIfError>()));
    });

    test('bare-bool предикат на enum-var → error', () {
      expect(
          () => validate({
                '#if': {
                  'and': ['@m'], // m — enum, не bool
                  'value': 1,
                },
              }),
          throwsA(isA<TemplateIfError>()));
    });

    test('#in на bool-var → error', () {
      expect(
          () => validate({
                '#if': {
                  'and': [
                    {
                      '@b': {
                        '#in': ['x'],
                      }
                    },
                  ],
                  'value': 1,
                },
              }),
          throwsA(isA<TemplateIfError>()));
    });

    test('неизвестный предикат-оператор (#frobnicate) → error', () {
      expect(
          () => validate({
                '#if': {
                  'and': [
                    {
                      '@t': {'#frobnicate': 1}
                    },
                  ],
                  'value': 1,
                },
              }),
          throwsA(isA<TemplateIfError>()));
    });

    test('битый #matches regexp → error', () {
      expect(
          () => validate({
                '#if': {
                  'and': [
                    {
                      '@t': {'#matches': '['}
                    },
                  ],
                  'value': 1,
                },
              }),
          throwsA(isA<TemplateIfError>()));
    });

    test('реальный bundled wizard_template.json проходит валидацию', () {
      // Регрессия: все #if-предикаты в шаблоне ссылаются на объявленные ноды
      // с совместимым типом. Ловит мои правки шаблона, если var не объявлена.
      final raw =
          File('assets/wizard_template.json').readAsStringSync();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final template = WizardTemplate.fromJson(json);
      final byName = <String, WizardVar>{
        for (final v in template.vars) v.name: v,
      };
      expect(
        () => validateIfConstructs(template.config, byName),
        returnsNormally,
      );
    });

    test('urltest_tolerance подставляется числом, а не строкой', () {
      // Регрессия: ядро sing-box требует URLTest.tolerance как uint16. Если
      // нода объявлена `text`, в конфиг попадёт "30" → "cannot unmarshal string
      // into Go struct field URLTestOutboundOptions.tolerance of type uint16".
      // Нода обязана быть `int`, тогда coerceVarValue вернёт число.
      final raw = File('assets/wizard_template.json').readAsStringSync();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final template = WizardTemplate.fromJson(json);
      final tol = template.vars.firstWhere((v) => v.name == 'urltest_tolerance');
      expect(tol.type, 'int',
          reason: 'tolerance в uint16-поле — нода должна коэрситься в int');

      final resolved = coerceVarValue(tol.defaultValue, tol.type);
      expect(resolved, isA<int>());
      expect(resolved, 30);
    });
  });
}
