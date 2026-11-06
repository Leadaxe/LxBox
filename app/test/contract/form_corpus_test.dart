import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/registry_form.dart';

import '../contract_paths.dart';

// §654 A — раннер корпуса `corpus/form/` (контракт 1.1.122, TASKS_LXBOX
// §119 п. 6, §120 — 1.1.123; формат — `corpus/form/README.md`): тело узла →
// что форма делает с ним по реестру — `visible`, `required`, `missing`,
// `choices`, `out_of_range`; кейс с `write` — тело после записи формы. Вычисление — `registry_form.dart`, тот же код, что у
// экрана. Пустой список и отсутствие ключа равнозначны.
void main() {
  setUpAll(loadTestRegistry);

  final root = Directory('$kVendorRoot/corpus/form');
  final files = root.existsSync()
      ? (root
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('_form.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  group('contract corpus: form', () {
    test('раздел не пуст', () {
      expect(files, isNotEmpty, reason: 'нет кейсов в ${root.path}');
    }, skip: corpusTestSkip('form_corpus_test', subpath: 'corpus/form'));

    for (final file in files) {
      final doc = (jsonDecode(file.readAsStringSync()) as Map)
          .cast<String, dynamic>();
      final scheme = '${doc['scheme']}';
      for (final c
          in ((doc['cases'] as List?) ?? const [])
              .cast<Map<String, dynamic>>()) {
        test('$scheme/${c['name']}', () {
          final layout = formLayoutFor(scheme);
          expect(layout, isNotNull, reason: 'у схемы $scheme нет формы');
          var body = ((c['body'] as Map?) ?? const {})
              .cast<String, dynamic>();
          final want = ((c['expect'] as Map?) ?? const {})
              .cast<String, dynamic>();
          // Контракт 1.1.123 — `write`: что форма пишет в тело перед
          // вычислением (значение + `form.implies` поля), `expect.body` —
          // тело после записи.
          final write = (c['write'] as Map?)?.cast<String, dynamic>();
          if (write != null) {
            final set = ((write['set'] as Map?) ?? const {})
                .cast<String, dynamic>();
            for (final p in set.keys.toList()..sort()) {
              expect(layout!.field(p), isNotNull, reason: 'write: $p');
              body = layout.write(body, p, set[p]);
            }
            for (final p in (write['clear'] as List?) ?? const []) {
              expect(layout!.field('$p'), isNotNull, reason: 'write: $p');
              body = layout.write(body, '$p', null);
            }
            expect(body, want['body'], reason: 'body');
          }
          final got = layout!.stateOf(body);

          List<String> list(String k) => [
            for (final e in (want[k] as List?) ?? const []) '$e',
          ];

          expect(got.visible, list('visible'), reason: 'visible');
          expect(got.required, list('required'), reason: 'required');
          expect(got.missing, list('missing'), reason: 'missing');
          expect(
            got.choices,
            ((want['choices'] as Map?) ?? const {}).map(
              (k, v) => MapEntry('$k', '$v'),
            ),
            reason: 'choices',
          );
          expect(
            [
              for (final v in got.outOfRange)
                {'path': v.path, 'value': v.value},
            ],
            [
              for (final v in (want['out_of_range'] as List?) ?? const [])
                {'path': '${v['path']}', 'value': v['value']},
            ],
            reason: 'out_of_range',
          );
        }, skip: corpusTestSkip('form_corpus_test', subpath: 'corpus/form'));
      }
    }
  });
}
