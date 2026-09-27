import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/screens/node_settings/node_document.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/contract/body_edit.dart';
import 'package:lxbox/services/contract/body_sanitizer.dart';
import 'package:lxbox/services/contract/warning_codes.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import '../contract_paths.dart';
import '../parser/engine_test_setup.dart';
import 'corpus_warnings.dart';

// §576 — раннер корпуса `corpus/node_edit/` (контракт 1.1.88–1.1.89,
// TASKS_LXBOX §85–§86): правка вкладки JSON окна узла → источник записи.
//
// `<case>.edit.json`: `container` (`own` | `folder` | `subscription`), прежний
// `origin` (`kind`, `raw`), `input` — текст вкладки JSON.
// `<case>.expected.json`: `origin` после правки (`raw` JSON-источника —
// объектом, сравнение по значению; прочий — строкой), `authored`,
// `rest_not_kept`, необязательно `warnings` (`code`, `path`, `applied`).
//
// Свой сервер и член папки: текст идёт через `prepareNodeDocumentForSave` —
// ту же функцию, что у экрана. Узел подписки: экран источник подписки не
// пишет (источник подписки — ответ провайдера), источник не меняется.
//
// §577 — у предупреждения сверяются `code`, `path` и `applied` (отсутствие
// = `true`).
//
// Раздел `corpus/authored/` (контракт 1.1.87–1.1.88): `<case>.body` — голое
// тело, сохранённое как свой сервер; ожидание — результат разбора с
// `meta.container: own`. Сверка СТРОГАЯ: тело (через ту же точку правки,
// что у сборки, `settleSanitized`), `warnings[]` с `applied`, `dropped[]`.
void main() {
  if (corpusSuiteUnavailable('test/contract/node_edit_corpus_test.dart')) {
    return;
  }

  setUpAll(loadEngineSections);

  final root = Directory('$kVendorRoot/corpus/node_edit');
  final cases = root.existsSync()
      ? (root
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.edit.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  group('contract corpus: node_edit', () {
    test('раздел не пуст', () {
      expect(cases, isNotEmpty, reason: 'нет кейсов в ${root.path}');
    });

    for (final file in cases) {
      final base =
          file.path.substring(0, file.path.length - '.edit.json'.length);
      final name = base.substring(root.path.length + 1);
      test(name, () {
        final edit =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final expected = jsonDecode(File('$base.expected.json')
            .readAsStringSync()) as Map<String, dynamic>;

        final container = edit['container'] as String;
        final origin = (edit['origin'] as Map).cast<String, dynamic>();
        final input = edit['input'] as String;
        final own = container == 'own' || container == 'folder';

        final String raw;
        final bool restNotKept;
        if (own) {
          final prep = prepareNodeDocumentForSave(input, '');
          expect(prep, isA<NodeDocumentReady>(),
              reason: prep is NodeDocumentRejected ? prep.message : '');
          raw = (prep as NodeDocumentReady).text;
          restNotKept = prep.droppedExtras;
        } else {
          raw = origin['raw'] as String;
          restNotKept = false;
        }

        final wantOrigin =
            (expected['origin'] as Map).cast<String, dynamic>();
        expect(originKindOf(raw), wantOrigin['kind'], reason: 'origin.kind');
        final wantRaw = wantOrigin['raw'];
        if (wantRaw is Map) {
          expect(jsonDecode(raw), wantRaw, reason: 'origin.raw по значению');
          expect(sourceKindOf(raw), 'singbox_outbound',
              reason: 'источник — голое тело узла');
        } else {
          expect(raw, wantRaw, reason: 'origin.raw строкой');
        }

        final authored = own && isAuthoredNodeSource(raw);
        expect(authored, expected['authored'], reason: 'authored');
        expect(restNotKept, expected['rest_not_kept'],
            reason: 'сообщение об остатке');

        final wantW = (expected['warnings'] as List?)
            ?.cast<Map<String, dynamic>>();
        if (wantW != null) {
          final node = parseAll(decode(raw), own: own).single;
          final scheme = (jsonDecode(raw) as Map)['type'] as String;
          final got = warningListOf(node.warnings, scheme);
          for (final w in wantW) {
            expect(
              got.any((g) =>
                  g['code'] == w['code'] &&
                  g['path'] == w['path'] &&
                  (g['applied'] ?? true) == (w['applied'] ?? true)),
              isTrue,
              reason: 'нет ${w['code']}@${w['path']}; есть: $got',
            );
          }
        }
      });
    }
  });

  final authoredRoot = Directory('$kVendorRoot/corpus/authored');
  final authoredCases = authoredRoot.existsSync()
      ? (authoredRoot
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.body'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  group('contract corpus: authored', () {
    test('раздел не пуст', () {
      expect(authoredCases, isNotEmpty, reason: 'нет кейсов в ${authoredRoot.path}');
    });

    for (final file in authoredCases) {
      final base = file.path.substring(0, file.path.length - '.body'.length);
      final name = base.substring(authoredRoot.path.length + 1);
      test(name, () {
        final text = file
            .readAsLinesSync()
            .skipWhile((l) => l.trimLeft().startsWith('#'))
            .join('\n');
        final expected = jsonDecode(File('$base.expected.json')
            .readAsStringSync()) as Map<String, dynamic>;
        expect((expected['meta'] as Map?)?['container'], 'own');
        expect(isAuthoredNodeSource(text), isTrue,
            reason: 'кейс раздела — голое тело sing-box');

        final dropped = <NodeWarning>[];
        final nodes = parseAll(decode(text), own: true, dropped: dropped);

        final gotDropped = [
          for (final w in dropped)
            '${w is RegistryWarning ? w.ownerTag : ''}|${warningCodeOf(w)}',
        ]..sort();
        final wantDropped = [
          for (final d in (expected['dropped'] as List?) ?? const [])
            '${(d as Map)['ref']}|${d['code']}',
        ]..sort();
        expect(gotDropped, wantDropped, reason: 'dropped[]');

        final wantNodes =
            ((expected['nodes'] as List?) ?? const []).cast<Map<String, dynamic>>();
        expect(nodes.length, wantNodes.length, reason: 'состав узлов');
        for (var i = 0; i < wantNodes.length; i++) {
          final want = wantNodes[i];
          final node = nodes[i];
          final scheme = '${want['scheme']}';
          expect(node.tag, want['label'], reason: 'label');

          final raw = (jsonDecode(text) as Map).cast<String, dynamic>();
          final type = raw['type'] as String;
          final res = settleSanitized(
            type,
            raw,
            RegistrySanitizer.sanitize(
              (jsonDecode(text) as Map).cast<String, dynamic>(),
              scheme: type,
              coreVersion: '0.0.0',
              applyCoreGates: false,
              source: BodySource.singbox,
            ),
            authored: true,
          );
          final entry = Map<String, dynamic>.from(res.body!)
            ..remove('tag')
            ..remove('detour');
          expect(canonEncode(entry), canonEncode(want['entry']),
              reason: 'тело узла');

          final gotW = warningListOf(node.warnings, scheme);
          final wantW = [
            for (final w in (want['warnings'] as List?) ?? const [])
              (w as Map).cast<String, dynamic>(),
          ];
          expect(canonEncode(gotW), canonEncode(wantW),
              reason: 'warnings[] (строго, с applied)');
        }
      });
    }
  });
}
