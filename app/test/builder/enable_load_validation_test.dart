import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/if_engine.dart';
import 'package:lxbox/services/template_loader.dart';

/// SPEC 393 фаза D (D4) — load-валидация тела `#enable` и симметрия секций.
///
/// До этого `validateIfConstructs` глотала `#enable` веткой
/// `if (k.startsWith('#')) continue` вместе с forward-compat директивами:
/// опечатка в имени переменной, оба ключа `and`+`or` сразу или скаляр вместо
/// условия грузились МОЛЧА. Рантайм fail-closed гасит узел — значит функция
/// молча исчезает из конфига, и причину без чтения кода не найти.
///
/// Второй разрыв — симметрия: Go валидирует `params`, `default_value` и
/// `config`, Dart звал валидатор ТОЛЬКО по `config`. Единственный `#enable`
/// боевого шаблона живёт в `selectable_rules[]`, то есть мимо `config` — до
/// D4 он не проверялся ни разу.

Map<String, dynamic> _shippedTemplate() => jsonDecode(
      File('assets/wizard_template.json').readAsStringSync(),
    ) as Map<String, dynamic>;

void main() {
  final nodes = <String, WizardVar>{
    'flag': WizardVar(name: 'flag', type: 'bool', defaultValue: 'false'),
    'other': WizardVar(name: 'other', type: 'bool', defaultValue: 'false'),
    'mode': WizardVar(name: 'mode', type: 'enum', defaultValue: 'vpn'),
  };

  void validate(dynamic config) => validateIfConstructs(config, nodes);

  group('D4 — #enable отвергается на load в трёх невалидных формах', () {
    test('опечатка в имени переменной → TemplateIfError', () {
      // Рантайм: предикат на необъявленное имя = false → узел выпадает молча.
      expect(
        () => validate({
          'node': {
            '#enable': ['@flga'],
            'y': 2,
          },
        }),
        throwsA(isA<TemplateIfError>()),
      );
    });

    test('оба ключа and+or сразу → TemplateIfError', () {
      expect(
        () => validate({
          'node': {
            '#enable': {
              '#and': ['@flag'],
              '#or': ['@other'],
            },
            'y': 2,
          },
        }),
        throwsA(isA<TemplateIfError>()),
      );
    });

    test('скаляр вместо условия → TemplateIfError', () {
      expect(
        () => validate({
          'node': {'#enable': 42, 'y': 2},
        }),
        throwsA(isA<TemplateIfError>()),
      );
    });

    test('сообщение об ошибке несёт путь до узла', () {
      // Путь — единственное, по чему разработчик находит место в шаблоне;
      // проверяется наличие сегмента, а не точная формулировка текста.
      try {
        validate({
          'outbounds': [
            {'tag': 'a'},
            {
              'tag': 'b',
              '#enable': ['@flga'],
            },
          ],
        });
        fail('ожидался TemplateIfError');
      } on TemplateIfError catch (e) {
        expect(e.message, contains('outbounds[1]'));
        expect(e.message, contains(r'#enable'));
      }
    });
  });

  group('D4 — валидные формы #enable грузятся', () {
    test('сахар: одиночная строка ≡ список из одного', () {
      expect(() => validate({'n': {'#enable': '@flag', 'y': 1}}),
          returnsNormally);
    });

    test('сахар: список ≡ and', () {
      expect(
        () => validate({
          'n': {
            '#enable': ['@flag', '@other'],
            'y': 1,
          },
        }),
        returnsNormally,
      );
    });

    test('cond-obj: or', () {
      expect(
        () => validate({
          'n': {
            '#enable': {
              'or': ['@flag', '@other'],
            },
          },
        }),
        returnsNormally,
      );
    });

    test('рекурсия: вложенный and внутри or (SPEC 107, снятие D-018)', () {
      expect(
        () => validate({
          'n': {
            '#enable': {
              '#or': [
                '@flag',
                {
                  '#and': ['@other', '@flag'],
                },
              ],
            },
          },
        }),
        returnsNormally,
      );
    });

    test('#not поверх cond-obj', () {
      expect(
        () => validate({
          'n': {
            '#enable': {
              '#not': {
                '#and': ['@flag'],
              },
            },
          },
        }),
        returnsNormally,
      );
    });

    test('предикат-объект с оператором', () {
      expect(
        () => validate({
          'n': {
            '#enable': [
              {
                '@mode': {
                  '#in': ['vpn', 'proxy'],
                },
              },
            ],
          },
        }),
        returnsNormally,
      );
    });

    test('строковая форма #in (ссылка на text_list-var)', () {
      // SPEC 103 C6: рантайм `_inList` эту форму исполняет — валидатор не
      // вправе быть строже собственного движка.
      final scope = <String, WizardVar>{
        ...nodes,
        'allowed':
            WizardVar(name: 'allowed', type: 'text_list', defaultValue: ''),
        'mode_text': WizardVar(name: 'mode_text', type: 'text', defaultValue: ''),
      };
      expect(
        () => validateIfConstructs({
          'n': {
            '#enable': [
              {
                '@mode_text': {'#in': '@allowed'},
              },
            ],
          },
        }, scope),
        returnsNormally,
      );
    });

    test('строковая форма #in на необъявленную var → error', () {
      expect(
        () => validate({
          'n': {
            '#enable': [
              {
                '@mode': {'#in': '@nowhere'},
              },
            ],
          },
        }),
        throwsA(isA<TemplateIfError>()),
      );
    });

    test('#enable:true не мешает #if того же узла', () {
      expect(
        () => validate({
          'n': {
            '#enable': ['@flag'],
            '#if': {
              '#and': ['@other'],
              '#value': {'x': 1},
            },
          },
        }),
        returnsNormally,
      );
    });
  });

  group('D4 — невалидные тела внутри валидной оболочки', () {
    test('пустой список предикатов → error', () {
      expect(() => validate({'n': {'#enable': <dynamic>[]}}),
          throwsA(isA<TemplateIfError>()));
    });

    test('bare-предикат на не-bool var → error', () {
      expect(() => validate({'n': {'#enable': ['@mode']}}),
          throwsA(isA<TemplateIfError>()));
    });

    test('неизвестный оператор внутри вложенного and → error', () {
      expect(
        () => validate({
          'n': {
            '#enable': {
              '#or': [
                {
                  '#and': [
                    {
                      '@mode': {'#frobnicate': 1},
                    },
                  ],
                },
              ],
            },
          },
        }),
        throwsA(isA<TemplateIfError>()),
      );
    });

    test('#enable внутри ветки #if тоже проверяется', () {
      expect(
        () => validate({
          '#if': {
            '#and': ['@flag'],
            '#value': {
              'inner': {
                '#enable': ['@typo'],
              },
            },
          },
        }),
        throwsA(isA<TemplateIfError>()),
      );
    });

    test('forward-compat сиблинг (не #if / не #enable) остаётся молчаливым',
        () {
      // Регрессия на границу ветки: проверка `k == enableKey` не должна
      // превратить неизвестную директиву будущей версии в ошибку загрузки.
      expect(() => validate({'n': {'#futureDirective': 42, 'y': 1}}),
          returnsNormally);
    });
  });

  group('D4 — симметрия секций и боевой шаблон', () {
    test('боевой wizard_template.json целиком проходит валидацию', () {
      final json = _shippedTemplate();
      final template = WizardTemplate.fromJson(json);
      expect(() => validateTemplateConstructs(json, template), returnsNormally);
    });

    test('боевой шаблон реально содержит #enable в selectable_rules', () {
      // Инвариант охвата: если #enable уедет из шаблона, тест выше станет
      // вырожденным и перестанет что-либо доказывать.
      final json = _shippedTemplate();
      var found = 0;
      void walkTree(dynamic n) {
        if (n is Map) {
          if (n.containsKey(enableKey)) found++;
          n.values.forEach(walkTree);
        } else if (n is List) {
          n.forEach(walkTree);
        }
      }

      walkTree(json['selectable_rules']);
      expect(found, greaterThan(0),
          reason: '#enable вне секции config — то, ради чего расширен рубеж');
    });

    test('сломанный #enable боевого шаблона отвергается на load', () {
      final json = _shippedTemplate();
      var patched = false;
      void breakEnable(dynamic n) {
        if (patched) return;
        if (n is Map) {
          if (n.containsKey(enableKey)) {
            n[enableKey] = ['@definitely_not_declared'];
            patched = true;
            return;
          }
          n.values.forEach(breakEnable);
        } else if (n is List) {
          n.forEach(breakEnable);
        }
      }

      breakEnable(json['selectable_rules']);
      expect(patched, isTrue, reason: 'узел с #enable должен был найтись');
      expect(
        () => validateTemplateConstructs(json, WizardTemplate.fromJson(json)),
        throwsA(isA<TemplateIfError>()),
      );
    });

    test('сломанный #if в selectable_rules отвергается на load', () {
      // Тела пресетов — мобильный аналог Go-секции params: до D4 не
      // проверялись вовсе.
      final json = _shippedTemplate();
      var patched = false;
      void breakIf(dynamic n) {
        if (patched) return;
        if (n is Map) {
          for (final k in n.keys.toList()) {
            if (isIfKey(k) && n[k] is Map) {
              final body = n[k] as Map;
              // добавляем второй ключ ветвления — «оба and+or сразу»
              body[body.containsKey('#and') ? '#or' : 'or'] = ['@vpn_mode'];
              patched = true;
              return;
            }
          }
          n.values.forEach(breakIf);
        } else if (n is List) {
          n.forEach(breakIf);
        }
      }

      breakIf(json['selectable_rules']);
      expect(patched, isTrue, reason: 'узел с #if должен был найтись');
      expect(
        () => validateTemplateConstructs(json, WizardTemplate.fromJson(json)),
        throwsA(isA<TemplateIfError>()),
      );
    });

    test('сломанный #on_change.#set отвергается на load', () {
      // Мобильный аналог Go-секции default_value: значение цели — #if-узел.
      final json = _shippedTemplate();
      var patched = false;
      void breakOnChange(dynamic vars) {
        for (final v in (vars as List? ?? const [])) {
          if (patched || v is! Map) continue;
          final oc = v['#on_change'] ?? v['on_change'];
          if (oc is! Map) continue;
          final set = oc['#set'] ?? oc['set'];
          if (set is! Map) continue;
          for (final target in set.keys) {
            final node = set[target];
            if (node is Map && node['#if'] is Map) {
              (node['#if'] as Map)['#and'] = ['@definitely_not_declared'];
              patched = true;
              return;
            }
          }
        }
      }

      for (final s in (json['sections'] as List)) {
        breakOnChange((s as Map)['vars']);
      }
      for (final r in (json['selectable_rules'] as List)) {
        breakOnChange((r as Map)['vars']);
      }
      expect(patched, isTrue, reason: 'var с #on_change должна была найтись');
      expect(
        () => validateTemplateConstructs(json, WizardTemplate.fromJson(json)),
        throwsA(isA<TemplateIfError>()),
      );
    });

    test('preset-local var видна валидатору тела своего пресета', () {
      // Область видимости: `geoip_enabled` объявлена ТОЛЬКО внутри пресета
      // ru-direct. Если бы scope был глобальным, боевой #enable был бы
      // отвергнут как ссылка на необъявленное имя.
      final json = _shippedTemplate();
      final template = WizardTemplate.fromJson(json);
      expect(template.vars.any((v) => v.name == 'geoip_enabled'), isFalse,
          reason: 'geoip_enabled — не глобальная var');
      expect(() => validateTemplateConstructs(json, template), returnsNormally);
    });
  });
}
