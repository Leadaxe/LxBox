import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/json_clone.dart';
import 'package:lxbox/services/lx_backup.dart';

// Конформанс-раннер корпуса LX Backup (SPEC 103, фаза 4), сторона LxBox.
// Тот же набор гоняет Go (core/backup/corpus_test.go).
//
// Перенос настроек между приложениями имеет смысл ровно настолько, насколько
// обе стороны одинаково понимают битую ссылку, непереносимую переменную и
// чужой блок extensions. Расхождение здесь = пользователь получит на телефоне
// не то, что видел на десктопе.

const _contractRoot = 'contract';

void main() {
  final root = Directory('$_contractRoot/corpus/backup');
  if (!root.existsSync()) return; // контракт не синхронизирован

  final cases = root
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.backup.json'))
      .map((f) =>
          f.path.substring(0, f.path.length - '.backup.json'.length))
      .toList()
    ..sort();

  group('contract corpus: LX Backup', () {
    for (final base in cases) {
      final name = base.substring(root.path.length + 1);
      test(name, () {
        final raw = File('$base.backup.json').readAsStringSync();
        // Per-app override читается ТАК ЖЕ, как в URI- и body-раннерах
        // (contract/corpus/README «Нормативность expected»): он означает
        // задокументированное by-design различие сторон, а его отсутствие —
        // что нормативна общая база и правка канона у лаунчера обязана
        // доехать до нас красным тестом.
        final overrideFile = File('$base.expected.lxbox.json');
        final baseFile = File('$base.expected.json');
        final expectedFile =
            overrideFile.existsSync() ? overrideFile : baseFile;
        final expected =
            jsonDecode(expectedFile.readAsStringSync()) as Map<String, dynamic>;

        final file = parseLxBackup(raw, knownOutbounds: {'proxy', 'direct'});

        // Коды предупреждений — часть контракта: они отвечают на вопрос
        // «что не применилось», и расхождение означает, что одна из сторон
        // молчит о потере.
        final gotCodes = file.warnings.map((w) => w.code).toSet().toList()..sort();
        final wantCodes =
            ((expected['warnings'] as List?) ?? const []).cast<String>().toList()
              ..sort();
        expect(gotCodes, wantCodes, reason: 'коды предупреждений');

        final wantRules =
            ((expected['rules'] as List?) ?? const []).cast<Map<String, dynamic>>();
        expect(file.rules, hasLength(wantRules.length), reason: 'число правил');
        for (var i = 0; i < wantRules.length; i++) {
          expect(file.rules[i].name, wantRules[i]['name'], reason: 'имя правила #$i');
          expect(file.rules[i].enabled, wantRules[i]['enabled'],
              reason: 'состояние правила ${wantRules[i]['name']}');
        }

        final wantVars = (expected['vars'] as Map?)?.cast<String, dynamic>();
        if (wantVars != null) {
          expect(file.vars, wantVars.map((k, v) => MapEntry(k, '$v')));
        }

        if (expected['route_final_applied'] == false) {
          expect(file.routeFinal, isNull);
        }

        // §393 B3 — Направления, созданные импортом (паритет с Go-раннером,
        // `corpus_test.go:checkDirections`). Сверяется КАНОНИЧЕСКАЯ форма, а
        // не внутренняя структура: именно о ней договорились стороны, и обе
        // читают одни и те же ожидания.
        final wantDirections =
            ((expected['directions'] as List?) ?? const []).cast<Map<String, dynamic>>();
        if (wantDirections.isNotEmpty) {
          final byTag = {for (final d in file.directions) d.tag: d};
          for (final want in wantDirections) {
            final tag = want['tag'] as String;
            final got = byTag[tag]!;
            expect(got, isNotNull, reason: 'направление $tag не создано импортом');
            // §405 — `label` УКАЗАТЕЛЬНОЙ семантики, как `enabled` у цепочек:
            // поле объявлено в схеме, но применяет его только LxBox (таблица
            // «Поддержка» BACKUP.md §2, D-094). Базовый golden пишет ожидания
            // ПРИНИМАЮЩЕЙ стороны лаунчера, у которого имени нет вовсе, и
            // отсутствие ключа там значит «сторона его не применяет», а не
            // «имя обязано быть пустым». Кейсы, где имя ПРОВЕРЯЕТСЯ, кладут
            // ключ явно — своим `.expected.lxbox.json` (chains_roundtrip).
            final wantLabel = want['label'];
            if (wantLabel is String) {
              expect(got.label, wantLabel, reason: '$tag: имя');
            }
            // Отбор узлов переносится ТЕЛОМ регулярки — у мобилы nodeFilter
            // уже хранит тело, обёртки и флагов в нём нет.
            expect(got.nodeFilter, want['filter'] ?? '', reason: '$tag: отбор');
            expect(got.nodeFilterInvert, want['invert'] ?? false,
                reason: '$tag: инверсия отбора');
            expect(got.includeDirect, want['include_direct'] ?? false,
                reason: '$tag: опция direct');
            expect(got.includeBlock, want['include_block'] ?? false,
                reason: '$tag: опция block');
            expect(got.auto != null, want['has_auto'] ?? false,
                reason: '$tag: автовыбор');
          }
        }

        // §393 C9 — цепочки хопов (SPEC 110, схема v1.2). Паритет с
        // Go-раннером (`corpus_test.go:checkChains`).
        //
        // Список ИСЧЕРПЫВАЮЩИЙ: проверяется и точное ЧИСЛО цепочек, иначе
        // запись, пропущенная merge'м по занятому тегу, могла бы тихо
        // материализоваться второй копией и тест бы этого не заметил.
        //
        // `chain` сверяется DEEP-EQUAL канона, без чувствительности к
        // порядку ключей и ВКЛЮЧАЯ `null` внутри `rewrite`: по RFC 7396
        // `null` удаляет ключ, то есть несёт смысл, и «схлопывание пустого»
        // на переносе поменяло бы патч.
        //
        // `label` проверяется НАТИВНО (у мобилы это хранимое поле
        // [SourceChain.label], а не непонятый груз `_backup_fields`, через
        // который его возит лаунчер) — но сверяется то же ожидание корпуса,
        // когда оно в кейсе есть (§405, указательная семантика ниже).
        final wantChains =
            ((expected['chains'] as List?) ?? const []).cast<Map<String, dynamic>>();
        if (wantChains.isNotEmpty) {
          expect(file.chains, hasLength(wantChains.length),
              reason: 'число цепочек: пропущенная merge\'ем запись не '
                  'должна материализоваться второй копией');
          final byTag = {for (final c in file.chains) c.tag: c};
          for (final want in wantChains) {
            final tag = want['tag'] as String;
            final got = byTag[tag]!;
            expect(got, isNotNull, reason: 'цепочка $tag не создана импортом');
            // §405 — та же указательная семантика, что у `directions[]`.
            final wantChainLabel = want['label'];
            if (wantChainLabel is String) {
              expect(got.label, wantChainLabel, reason: '$tag: имя');
            }
            // enabled — УКАЗАТЕЛЬНАЯ семантика (контракт 0.7.1, кейс
            // chain_disabled_enabled_default): отсутствие ключа в ожиданиях =
            // «не проверяем», НЕ «ожидаем false». Обычный bool с дефолтом
            // потребовал бы выключенности во всех кейсах без поля.
            final wantEnabled = want['enabled'];
            if (wantEnabled is bool) {
              expect(got.enabled, wantEnabled,
                  reason: '$tag: enabled — отсутствие ключа в записи файла '
                      'обязано читаться как true, явный false — как false');
            }
            expect(
              _canonOf(got),
              _deepEqualsJson(want['chain']),
              reason: '$tag: канон цепочки искажён',
            );
          }
        }

        // §393 B12 — отметки выключенных узлов (§4 BACKUP.md). Паритет с
        // Go-раннером (`corpus_test.go:checkDisabledHashes`): переносятся
        // ТОЛЬКО по identity-хешу, ожидание — плоский список хешей, которые
        // обязаны найтись хоть у одной подписки. Тег и подпись у сторон
        // разные, сопоставлять по ним нечего.
        final wantHashes =
            ((expected['disabled_hashes'] as List?) ?? const []).cast<String>();
        if (wantHashes.isNotEmpty) {
          final found = <String>{
            for (final s in file.subscriptions) ...s.disabled.keys,
          };
          for (final want in wantHashes) {
            expect(found, contains(want),
                reason: 'отметка выключенной ноды $want не перенесена');
          }
        }

        // §401 / контракт 0.12 — ПАПКА. Схема контейнеров не знает: члены
        // папки едут ОТДЕЛЬНЫМИ записями `servers[]` с полем `folder`, а
        // собирает их обратно импорт по совпадению имени. Ожидание — карта
        // {имя папки → теги членов}: проверяется и состав, и то, что запись
        // БЕЗ `folder` в папку не затесалась.
        final wantFolders = (expected['folders'] as Map?)?.cast<String, dynamic>();
        if (wantFolders != null) {
          final gotFolders = <String, List<String>>{};
          for (final srv in file.servers) {
            if (srv.folder.isEmpty) continue;
            (gotFolders[srv.folder] ??= <String>[]).add(srv.name);
          }
          expect(gotFolders.keys.toSet(), wantFolders.keys.toSet(),
              reason: 'состав папок: имена');
          for (final entry in wantFolders.entries) {
            expect(gotFolders[entry.key], (entry.value as List).cast<String>(),
                reason: 'папка ${entry.key}: состав и порядок членов');
          }
        }

        // §401 — упразднённый механизм `extensions` (схема 0.10.x): импортёр
        // обязан отбросить его и назвать ОДНИМ warning'ом на файл, а не
        // провозить до следующего экспорта (BACKUP_PRINCIPLES.md П3).
        if (expected['extensions_dropped'] == true) {
          expect(
              file.warnings.where((w) => w.code == kWarnExtensionsDropped),
              hasLength(1),
              reason: 'карман extensions обязан дать ровно один warning '
                  'на файл с перечнем затронутых записей');
        }
      });
    }
  });
}

/// Канон цепочки (`schema/source_chain.schema.json`) из мобильной модели —
/// ровно поля маршрута, без идентичности записи (`tag`/`label`/`enabled`),
/// которая в схеме живёт уровнем выше.
Map<String, dynamic> _canonOf(SourceChain c) => c.toJson()
  ..remove('tag')
  ..remove('label')
  ..remove('enabled');

/// Матчер структурного равенства JSON-деревьев: нечувствителен к порядку
/// ключей и НЕ схлопывает `null` (RFC 7396 — он удаляет ключ, а не значит
/// «пусто»). `equals` для вложенных Map/List этого не даёт.
Matcher _deepEqualsJson(Object? want) =>
    predicate<Object?>((got) => deepEqualsJson(got, want), 'deep-equals $want');
