import 'package:flutter_test/flutter_test.dart';

// §285 Ф3 — self-test AST-скана + валидации ui_check. Логика вынесена в
// tool/l10n/src/ui_scan.dart ровно ради этого теста (entrypoint
// tool/l10n/ui_check.dart стабилен для CI). Проверяем: экстракцию ключей из
// call-site'ов (getLocalText/t/loc/GetLocalText.en, .s/.plural, int-индекс
// формы, динамические ключи), и все ветки validateUiKeys (missing, orphan,
// orphan-special, usage-conflict, shape, arity) на синтетическом словаре.

import '../../tool/l10n/src/ui_scan.dart';

const _forms = {'one', 'few', 'many', 'other'};

UiScanResult scan(String src) =>
    scanForUiKeys(path: 'test.dart', content: src);

UiValidation validate(List<UiKeyUse> uses, Map<String, dynamic> dict,
        {int dynamicCount = 0}) =>
    validateUiKeys(
        uses: uses, dynamicCount: dynamicCount, dict: dict, forms: _forms);

UiKeyUse use(String key, {int form = 0, bool plural = false}) =>
    UiKeyUse(file: 'f', line: 1, key: key, formIndex: form, isPlural: plural);

void main() {
  group('AST scan — key extraction', () {
    test('getLocalText.s literal key', () {
      final r = scan('final x = getLocalText.s("Connected");');
      expect(r.uses, hasLength(1));
      expect(r.uses.single.key, 'Connected');
      expect(r.uses.single.formIndex, 0);
      expect(r.uses.single.isPlural, isFalse);
      expect(r.dynamicKeys, isEmpty);
    });

    test('leading int is a special form index', () {
      final r = scan('final x = getLocalText.s(1, "App");');
      expect(r.uses.single.key, 'App');
      expect(r.uses.single.formIndex, 1);
    });

    test('.plural collected with isPlural', () {
      final r = scan('final x = getLocalText.plural("%d servers", n);');
      expect(r.uses.single.key, '%d servers');
      expect(r.uses.single.isPlural, isTrue);
    });

    test('t/loc receivers (renderWith-параметр) collected', () {
      final r = scan('''
String m(t) => t.s("Failed");
String r2(loc) => loc.plural("%d min ago", 3);
''');
      expect(r.uses.map((u) => u.key),
          unorderedEquals(['Failed', '%d min ago']));
    });

    test('GetLocalText.en receiver collected', () {
      final r = scan('final x = GetLocalText.en.s("Stopped");');
      expect(r.uses.single.key, 'Stopped');
    });

    test('unrelated .s/.plural receiver is ignored', () {
      final r = scan('final x = foo.s("nope"); final y = bar.plural("no", 1);');
      expect(r.uses, isEmpty);
      expect(r.dynamicKeys, isEmpty);
    });

    test('interpolated / variable key is dynamic, not a literal use', () {
      final r = scan(r'''
final a = getLocalText.s("Host: $host");
final b = getLocalText.s(label);
''');
      expect(r.uses, isEmpty);
      expect(r.dynamicKeys, hasLength(2));
    });

    test('adjacent string literals concatenate into one key', () {
      final r = scan('final x = getLocalText.s("Long " "key");');
      expect(r.uses.single.key, 'Long key');
    });
  });

  group('validation — missing / orphan', () {
    test('key used in code but absent from dict = missing', () {
      final v = validate([use('Gone')], {});
      expect(v.missing, 1);
      expect(
          v.findings.where((f) => f.kind == UiFindingKind.missing), hasLength(1));
    });

    test('dict key never referenced = orphan', () {
      final v = validate([use('Live')], {
        'Live': {'value': 'Живой'},
        'Dead': {'value': 'Мёртвый'},
      });
      expect(v.orphan, 1);
      expect(v.findings.single.kind, UiFindingKind.orphan);
    });

    test('clean set has no findings', () {
      final v = validate([use('Ok')], {
        'Ok': {'value': 'Ок'},
      });
      expect(v.findings, isEmpty);
      expect(v.keys, 1);
    });
  });

  group('validation — shape', () {
    test('.plural with incomplete plural forms fails', () {
      final v = validate([use('%d apps', plural: true)], {
        '%d apps': {
          'value': {'one': '%d прил.', 'other': '%d прил.'} // missing few/many
        },
      });
      final shapes = v.findings.where((f) => f.kind == UiFindingKind.shape);
      expect(shapes, hasLength(1));
      expect(shapes.single.message, contains('missing forms'));
      expect(v.hasFail, isTrue);
    });

    test('.plural with a plain string value fails', () {
      final v = validate([use('%d apps', plural: true)], {
        '%d apps': {'value': '%d прил.'},
      });
      expect(v.findings.single.kind, UiFindingKind.shape);
    });

    test('.s with a plural-object value fails', () {
      final v = validate([use('App')], {
        'App': {
          'value': {'one': 'x', 'few': 'x', 'many': 'x', 'other': 'x'}
        },
      });
      expect(v.findings.single.kind, UiFindingKind.shape);
    });

    test('key used both .s and .plural = usage conflict', () {
      final v = validate([use('Dual'), use('Dual', plural: true)], {
        'Dual': {'value': 'x'},
      });
      expect(v.findings.any((f) => f.kind == UiFindingKind.usageConflict),
          isTrue);
      expect(v.hasFail, isTrue);
    });
  });

  group('validation — special forms', () {
    test('special index used in code but absent in dict fails', () {
      final v = validate([use('App', form: 1)], {
        'App': {'value': 'Приложение'}, // no special
      });
      expect(v.findings.any((f) => f.kind == UiFindingKind.shape), isTrue);
    });

    test('special defined but never used with that index = orphan-special', () {
      final v = validate([use('App')], {
        'App': {
          'value': 'Приложение',
          'special': {
            '1': {'value': 'Прил.'}
          }
        },
      });
      expect(v.findings.any((f) => f.kind == UiFindingKind.orphanSpecial),
          isTrue);
    });

    test('matching root + special use is clean', () {
      final v = validate([use('App'), use('App', form: 1)], {
        'App': {
          'value': 'Приложение',
          'special': {
            '1': {'value': 'Прил.'}
          }
        },
      });
      expect(v.findings, isEmpty);
    });
  });

  group('validation — placeholder arity', () {
    test('arity mismatch (key vs value) fails', () {
      final v = validate([use('%1\$s at %2\$s')], {
        '%1\$s at %2\$s': {'value': 'только %1\$s'}, // dropped %2$s
      });
      expect(v.arityErrors, 1);
      expect(v.findings.single.kind, UiFindingKind.arity);
    });

    test('matching arity passes', () {
      final v = validate([use('%1\$s at %2\$s')], {
        '%1\$s at %2\$s': {'value': '%2\$s: %1\$s'},
      });
      expect(v.findings, isEmpty);
    });

    test('arity checked per plural form', () {
      final v = validate([use('%d apps', plural: true)], {
        '%d apps': {
          'value': {
            'one': '%d прил.',
            'few': 'прил.', // missing %d
            'many': '%d прил.',
            'other': '%d прил.',
          }
        },
      });
      expect(v.arityErrors, 1);
    });
  });

  group('placeholderSlots', () {
    test('sequential %s/%d numbered in order', () {
      expect(placeholderSlots('%s and %d'), {1, 2});
    });
    test('explicit %K\$ positions', () {
      expect(placeholderSlots('%2\$s %1\$d'), {1, 2});
    });
    test('%% is literal, not a slot', () {
      expect(placeholderSlots('100%% done %s'), {1});
    });
    test('no placeholders', () {
      expect(placeholderSlots('plain'), isEmpty);
    });
  });

  test('dynamicCount is threaded into validation', () {
    final v = validate([use('Ok')], {
      'Ok': {'value': 'Ок'},
    }, dynamicCount: 5);
    expect(v.dynamicSkipped, 5);
  });
}
