import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/server_list.dart';
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

  // §407 — предсостояние (`<case>.pre.backup.json`) кейсом НЕ является:
  // раннер обязан отсеять его из списка, иначе погонит его отдельным
  // прогоном и будет искать несуществующий `<case>.pre.expected.json`
  // (`contract/corpus/README.md`, «Предсостояние кейса»).
  final cases = root
      .listSync()
      .whereType<File>()
      .where((f) =>
          f.path.endsWith('.backup.json') && !f.path.endsWith('.pre.backup.json'))
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

        // §407 — ПРЕДСОСТОЯНИЕ. Слияние нельзя проверить импортом в пустоту:
        // там слияние и замена дают один и тот же итог. Кейс, который его
        // проверяет, кладёт рядом `<case>.pre.backup.json`; порядок строгий —
        // пустое состояние → импорт `pre` → импорт самого кейса → сверка.
        //
        // «Состояние» здесь — то же, что у приложения: список источников
        // (`List<ServerList>`). Собирается он ТЕМИ ЖЕ чистыми функциями,
        // которыми его собирает импорт (`_applySources` в
        // `screens/backup_screen.dart`): расхождение раннера и приложения
        // означало бы, что зелёный корпус ничего не гарантирует.
        //
        // Предупреждения предсостояния в сверку НЕ идут: оно декорация сцены,
        // а не предмет кейса.
        final preFile = File('$base.pre.backup.json');
        var state = <ServerList>[];
        if (preFile.existsSync()) {
          final pre = parseLxBackup(preFile.readAsStringSync(),
              knownOutbounds: {'proxy', 'direct'});
          state = _applySources(state, pre);
        }

        final file = parseLxBackup(raw, knownOutbounds: {'proxy', 'direct'});
        state = _applySources(state, file);

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
        //
        // §407 — состав читается из СОСТОЯНИЯ после слияния, а не из разбора
        // файла: до 0.12.5 папку описывал один файл целиком, а с
        // предсостоянием её половина приезжает первым импортом, и разбор
        // второго о ней уже ничего не знает.
        final wantFolders = (expected['folders'] as Map?)?.cast<String, dynamic>();
        if (wantFolders != null) {
          final gotFolders = <String, List<String>>{
            for (final l in state)
              if (l is FolderServers)
                l.name: [for (final m in l.members) m.node?.tag ?? ''],
          };
          expect(gotFolders.keys.toSet(), wantFolders.keys.toSet(),
              reason: 'состав папок: имена');
          for (final entry in wantFolders.entries) {
            expect(gotFolders[entry.key], (entry.value as List).cast<String>(),
                reason: 'папка ${entry.key}: состав и порядок членов');
          }
        }

        // §407 (D-095, BACKUP.md §9 п.1) — ПОДПИСКИ после слияния. Ожидание
        // ИСЧЕРПЫВАЮЩЕЕ: подписка, которой в нём нет, — это либо не
        // оставленная локальная, либо задвоенная, и обе ошибки видны только
        // сверкой всего набора, а не поиском отдельных ключей.
        //
        // `postfix` у LxBox поля не имеет вовсе (тег источника здесь только
        // префикс), поэтому сверяется с пустой строкой: ожидание корпуса
        // пишет `""` ровно в том же смысле — «постфикса нет».
        final wantSubs =
            (expected['subscriptions'] as Map?)?.cast<String, dynamic>();
        if (wantSubs != null) {
          final gotSubs = <String, SubscriptionServers>{
            for (final l in state)
              if (l is SubscriptionServers) l.url: l,
          };
          expect(gotSubs.keys.toSet(), wantSubs.keys.toSet(),
              reason: 'набор подписок после слияния: ключ — url байт в байт');
          for (final entry in wantSubs.entries) {
            final got = gotSubs[entry.key]!;
            final want = (entry.value as Map).cast<String, dynamic>();
            expect(got.name, want['label'], reason: '${entry.key}: label');
            expect(got.tagPrefix, want['prefix'] ?? '',
                reason: '${entry.key}: префикс тегов');
            expect('', want['postfix'] ?? '',
                reason: '${entry.key}: постфикс тегов — поля у LxBox нет');
            final wantEnabled = want['enabled'];
            if (wantEnabled is bool) {
              expect(got.enabled, wantEnabled, reason: '${entry.key}: enabled');
            }
            final wantNodes = (want['nodes'] as List?)?.cast<String>();
            if (wantNodes != null) {
              // Состав локальной подписки в файл не едет и потеряться на
              // слиянии не вправе.
              expect([for (final n in got.nodes) n.tag], wantNodes,
                  reason: '${entry.key}: состав узлов пережил слияние');
            }
            final wantPending = (want['pending_disabled'] as List?)?.cast<String>();
            if (wantPending != null) {
              // Объединение двух множеств отметок: порядок в нём смысла не
              // несёт, поэтому сверка отсортированная.
              expect(got.disabledHashes.keys.toList()..sort(),
                  wantPending.toList()..sort(),
                  reason: '${entry.key}: отметки выключения ОБЪЕДИНЯЮТСЯ, '
                      'а не замещаются файлом');
            }
          }
        }

        // §407 (BACKUP.md §9 п.2) — КОРНЕВЫЕ одиночные узлы в порядке
        // состояния: совпавшие по телу держат локальную позицию, новые встают
        // в конец. Дедуп по телу проверяется именно ОТСУТСТВИЕМ второй записи
        // в этом списке, а не наличием первой.
        final wantRootServers = (expected['root_servers'] as List?)?.cast<String>();
        if (wantRootServers != null) {
          expect([
            for (final l in state)
              if (l is UserServer) l.name,
          ], wantRootServers, reason: 'корневые одиночные узлы: состав и порядок');
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

/// §407 — сборка состояния источников теми же чистыми функциями, которыми её
/// делает импорт приложения (`_applySources`, `screens/backup_screen.dart`):
/// сперва подписки по `url`, затем одиночные узлы и папки по телу. Раннер
/// отличается от приложения только тем, что состояние держит в списке, а не
/// в storage — сама норма слияния живёт в одном месте на оба вызова.
List<ServerList> _applySources(List<ServerList> state, LxBackupFile file) {
  final subs = mergeBackupSubscriptions(state, file.subscriptions);
  return mergeBackupServers(subs.lists, file.servers).lists;
}
