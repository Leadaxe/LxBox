import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/record_codec.dart';
import 'package:lxbox/models/node_sections.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/dns/dns_backup.dart';
import 'package:lxbox/services/json_clone.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/tag_resolver.dart';

// Конформанс-раннер корпуса LX Backup (SPEC 103, фаза 4), сторона LxBox.
// Тот же набор гоняет Go (core/backup/corpus_test.go).
//
// Перенос настроек между приложениями имеет смысл ровно настолько, насколько
// обе стороны одинаково понимают битую ссылку, непереносимую переменную и
// чужой блок extensions. Расхождение здесь = пользователь получит на телефоне
// не то, что видел на десктопе.
//
// §438 — кейсы лежат в двух форматах (`lx_backup: 1` и `2`). Раннер формат не
// выбирает: импорт опознаёт его сам, дальше одно слияние на оба.

const _contractRoot = 'contract';

/// Кейсы, которые сторона пока не проходит по известной причине: имя кейса →
/// причина пропуска. Ожидание кейса не подгоняется — запись снимается вместе
/// с работой, которая его закрывает.
const Map<String, String> _pendingCases = {
  // Ссылка на узел подписки без узлов (`{folder_id: <подписка>, tag: US-1}`)
  // и висячая ссылка (`folder_id` без контейнера) моделью, которая держит
  // финальный тег строкой, не выражаются (§439 §6.4, NODE_LINK.md).
  'v10_node_links': 'до трека N1: модели держат ссылку на узел финальным '
      'тегом строкой, NodeLink {folder_id, tag} в моделях — трек N1',
};


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
      test(name, skip: _pendingCases[name], () {
        final raw = File('$base.backup.json').readAsStringSync();
        // Кейс формата новее ЧИТАЕМОГО (`lx_backup` выше
        // kLxBackupVersion) сторона ПРОПУСКАЕТ по маркеру, как чужой
        // extension, без override-файлов (`contract/corpus/README.md`).
        final marker = jsonDecode(raw);
        if (marker is Map &&
            marker['lx_backup'] is num &&
            (marker['lx_backup'] as num) > kLxBackupVersion) {
          markTestSkipped('формат lx_backup ${marker['lx_backup']} новее '
              'читаемого $kLxBackupVersion');
          return;
        }
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
        // там слияние и замена дают один и тот же итог. Порядок строгий —
        // пустое состояние → импорт `pre` → импорт самого кейса → сверка.
        //
        // Предупреждения предсостояния в сверку НЕ идут: оно декорация сцены,
        // а не предмет кейса.
        final state = _State();
        final preFile = File('$base.pre.backup.json');
        if (preFile.existsSync()) {
          state.import(preFile.readAsStringSync());
        }
        final file = state.import(raw);

        // Коды предупреждений — часть контракта: они отвечают на вопрос
        // «что не применилось», и расхождение означает, что одна из сторон
        // молчит о потере.
        final gotCodes = file.warnings.map((w) => w.code).toSet().toList()..sort();
        final wantCodes =
            ((expected['warnings'] as List?) ?? const []).cast<String>().toList()
              ..sort();
        expect(gotCodes, wantCodes, reason: 'коды предупреждений');

        _checkWarningReasons(file, expected);
        _checkRules(state, expected);

        final wantVars = (expected['vars'] as Map?)?.cast<String, dynamic>();
        if (wantVars != null) {
          expect(file.vars, wantVars.map((k, v) => MapEntry(k, '$v')));
        }

        if (expected['route_final_applied'] == false) {
          expect(file.routeFinal, isNull);
        }

        _checkDirections(file, expected);
        _checkChains(state, expected);
        _checkDetours(state, expected);

        // §393 B12 — отметки выключенных узлов (§4 BACKUP.md). Паритет с
        // Go-раннером (`corpus_test.go:checkDisabledHashes`): ожидание —
        // плоский список ключей, которые обязаны найтись хоть у одной
        // подписки. Ключ для формата обмена непрозрачен.
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

        _checkFolders(state, expected);
        _checkSubscriptions(state, expected);

        // §407 (BACKUP.md §9 п.2) — КОРНЕВЫЕ одиночные узлы в порядке
        // состояния: совпавшие по телу держат локальную позицию, новые встают
        // в конец. Дедуп по телу проверяется именно ОТСУТСТВИЕМ второй записи
        // в этом списке, а не наличием первой.
        final wantRootServers = (expected['root_servers'] as List?)?.cast<String>();
        if (wantRootServers != null) {
          expect([
            for (final l in state.lists)
              if (l is UserServer) l.name,
          ], wantRootServers, reason: 'корневые одиночные узлы: состав и порядок');
        }

        _checkDns(state, expected);
        _checkSections(state, expected);

        // `replace_tags` не сверяется: свёртки источника в группу у LxBox нет
        // (BACKUP.md §2, `fold`/`fold_tag` — поля лаунчера; класс различия A
        // в `replace_tag_index.expected.lxbox.json`).

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

/// Состояние раннера — то же, что у приложения: списки источников, цепочки,
/// правила и DNS. Собирается оно ТЕМИ ЖЕ чистыми функциями, которыми его
/// собирает импорт (`_onLxImport` в `screens/backup_screen.dart`):
/// расхождение раннера и приложения означало бы, что зелёный корпус ничего
/// не гарантирует. Раннер отличается только тем, что держит состояние в
/// памяти, а не в storage.
class _State {
  List<ServerList> lists = [];
  List<SourceChain> chains = [];
  List<CustomRule> rules = [];
  List<DnsServerRef> dnsServers = [];
  List<DnsRuleRef> dnsRules = [];
  String dnsFinal = '';
  String dnsStrategy = '';
  String dnsResolver = '';

  LxBackupFile import(String raw) {
    final file = parseLxBackup(
      raw,
      knownOutbounds: {'proxy', 'direct'},
      knownChains: {for (final c in chains) c.tag},
    );
    final subs = mergeBackupSubscriptions(lists, file.subscriptions);
    final servers = mergeBackupServers(
      subs.lists,
      file.servers,
      folders: file.folders,
      sourceIds: subs.ids,
      addedSources: subs.added,
      sourceDetours: subs.detours,
    );
    lists = servers.lists;
    chains = [
      ...chains,
      ...resolveBackupChainHops(file, servers.lists, servers.folderIds),
    ];
    // `rules[]` — единственная секция полной замены (BACKUP.md §9 п. 7).
    rules = renumberBackupAxis(file.rules, servers.lists, servers.touched);
    final dns = file.dns;
    if (dns != null && !dns.isEmpty) {
      final applied = applyDnsBackup(
        incoming: dns,
        servers: dnsServers,
        rules: dnsRules,
        dnsFinal: dnsFinal,
        strategy: dnsStrategy,
        defaultDomainResolver: dnsResolver,
      );
      dnsServers = applied.servers;
      dnsRules = applied.rules;
      dnsFinal = applied.dnsFinal;
      dnsStrategy = applied.strategy;
      dnsResolver = applied.defaultDomainResolver;
    }
    return file;
  }

  /// Носители секций: корневые узлы (по имени записи) и члены папок (по тегу
  /// узла) — у члена папки свой путь слияния.
  Map<String, NodeSections> get sections => {
        for (final l in lists)
          if (l is UserServer && l.sections != null) l.name: l.sections!,
        for (final l in lists)
          if (l is FolderServers)
            for (final m in l.members)
              if (m.sections != null && m.node != null) m.node!.tag: m.sections!,
      };
}

/// §438 — причины у кодов, где причина нормирована перечнем
/// (`backup_section_record_dropped`: `kind` | `rule_set` | `not_allowed`).
/// Множество кодов их не различает, и сторона, отбросившая запись «не по той
/// причине», показала бы пользователю неверное объяснение потери.
void _checkWarningReasons(LxBackupFile file, Map<String, dynamic> expected) {
  final want = (expected['warning_reasons'] as Map?)?.cast<String, dynamic>();
  if (want == null) return;
  for (final entry in want.entries) {
    final got = <String>{
      for (final w in file.warnings)
        if (w.code == entry.key) w.reason,
    };
    expect(got, isNot(contains('')),
        reason: '${entry.key}: предупреждение без reason, а перечень причин '
            'нормирован');
    expect(got.toList()..sort(), (entry.value as List).cast<String>().toList()..sort(),
        reason: '${entry.key}: причины');
  }
}

/// ОСЬ ПОРЯДКА целиком: корневые правила и правила, которые узлы носят с
/// собой (NODE_SECTIONS.md §5). Проверять её половинами нельзя: узловое
/// правило встаёт МЕЖДУ корневыми по относительному порядку номеров, и
/// список одних корневых этого не покажет.
void _checkRules(_State state, Map<String, dynamic> expected) {
  final wantRules =
      ((expected['rules'] as List?) ?? const []).cast<Map<String, dynamic>>();
  final indexed = <(int, int, CustomRule)>[];
  var seq = 0;
  for (final r in state.rules) {
    indexed.add((r.orderNum ?? 1 << 30, seq++, r));
  }
  for (final s in state.sections.values) {
    for (final r in s.rules) {
      indexed.add((r.orderNum ?? kNodeRuleDefaultNum, seq++, r));
    }
  }
  indexed.sort((a, b) {
    final byNum = a.$1.compareTo(b.$1);
    return byNum != 0 ? byNum : a.$2.compareTo(b.$2);
  });
  final axis = [for (final e in indexed) e.$3];

  expect(axis, hasLength(wantRules.length), reason: 'число правил на оси');
  for (var i = 0; i < wantRules.length; i++) {
    final want = wantRules[i];
    final got = axis[i];
    expect(got.name, want['name'], reason: 'имя правила #$i');
    expect(got.enabled, want['enabled'],
        reason: 'состояние правила ${want['name']}');
    // ## 12 (D-100) — `refs` в ожиданиях необязателен: нет ключа — не
    // проверяем; есть — все наборы правила по порядку.
    final wantRefs = want['refs'];
    if (wantRefs is List) {
      expect(got.srsUrls, wantRefs.cast<String>(),
          reason: 'refs правила ${want['name']}');
    }
    // §438 — цель как вид: тег | `reject` | `drop`. У preset цели нет —
    // она из шаблона, и ожидание её не несёт.
    final wantOutbound = want['outbound'];
    if (wantOutbound is String && wantOutbound.isNotEmpty) {
      expect(_outboundView(got), wantOutbound,
          reason: 'цель правила ${want['name']}');
    }
    // D-111 — тело правила deep-equal: у json-правила — его текст, у
    // остальных — `body` записи хранения.
    if (want.containsKey('body')) {
      final gotBody = got is CustomRuleJson
          ? jsonDecode(got.json)
          : ruleToRecord(got)['body'];
      expect(gotBody, _deepEqualsJson(want['body']),
          reason: 'тело правила ${want['name']}');
    }
    // §438 — переменные ЭТОГО правила (preset), не глобальные `vars`.
    final wantVars = want['vars'];
    if (wantVars is Map) {
      expect(got is CustomRulePreset ? got.varsValues : null,
          wantVars.map((k, v) => MapEntry('$k', '$v')),
          reason: 'переменные правила ${want['name']}');
    }
  }
}

/// Цель правила так, как её видит ядро: `reject`/`drop` — отказ, иначе тег.
/// У правила вида json цель читается из тела.
String _outboundView(CustomRule r) {
  if (r is CustomRuleJson) {
    final body = jsonDecode(r.json);
    if (body is! Map) return '';
    if (body['action'] == 'reject') {
      return body['method'] == 'drop' ? 'drop' : 'reject';
    }
    return body['outbound'] is String ? body['outbound'] as String : '';
  }
  if (r is CustomRulePreset) return '';
  return r.outbound == kOutboundReject ? 'reject' : r.outbound;
}

/// §393 B3 — Направления, созданные импортом (паритет с Go-раннером,
/// `corpus_test.go:checkDirections`). Сверяется КАНОНИЧЕСКАЯ форма, а не
/// внутренняя структура: именно о ней договорились стороны.
void _checkDirections(LxBackupFile file, Map<String, dynamic> expected) {
  final wantDirections =
      ((expected['directions'] as List?) ?? const []).cast<Map<String, dynamic>>();
  if (wantDirections.isEmpty) return;
  final byTag = {for (final d in file.directions) d.tag: d};
  for (final want in wantDirections) {
    final tag = want['tag'] as String;
    final got = byTag[tag];
    expect(got, isNotNull, reason: 'направление $tag не создано импортом');
    // §405 — `label` УКАЗАТЕЛЬНОЙ семантики: поле объявлено в схеме, но
    // применяет его только LxBox (D-094). Отсутствие ключа в базовом golden
    // значит «сторона его не применяет», а не «имя обязано быть пустым».
    final wantLabel = want['label'];
    if (wantLabel is String) {
      expect(got!.label, wantLabel, reason: '$tag: имя');
    }
    // Отбор узлов переносится ТЕЛОМ регулярки — у мобилы nodeFilter уже
    // хранит тело, обёртки и флагов в нём нет.
    expect(got!.nodeFilter, want['filter'] ?? '', reason: '$tag: отбор');
    expect(got.nodeFilterInvert, want['invert'] ?? false,
        reason: '$tag: инверсия отбора');
    expect(got.includeDirect, want['include_direct'] ?? false,
        reason: '$tag: опция direct');
    expect(got.includeBlock, want['include_block'] ?? false,
        reason: '$tag: опция block');
    expect(got.auto != null, want['has_auto'] ?? false,
        reason: '$tag: автовыбор');
    // §409 — бюджет теста узла, та же указательная семантика, что у `label`.
    final gotPing = file.directionPing[tag];
    final wantPingUrl = want['ping_url'];
    if (wantPingUrl is String) {
      expect(gotPing?.url, wantPingUrl, reason: '$tag: URL теста');
    }
    final wantPingTimeout = want['ping_timeout_ms'];
    if (wantPingTimeout is num) {
      expect(gotPing?.timeoutMs, wantPingTimeout.toInt(),
          reason: '$tag: таймаут теста');
    }
  }
}

/// §393 C9 — цепочки хопов (SPEC 110). Список ИСЧЕРПЫВАЮЩИЙ: точное ЧИСЛО
/// цепочек, иначе запись, пропущенная merge'м по занятому тегу, могла бы тихо
/// материализоваться второй копией.
///
/// `chain` сверяется DEEP-EQUAL канона, без чувствительности к порядку ключей
/// и ВКЛЮЧАЯ `null` внутри `rewrite` (RFC 7396).
///
/// §438 — `hops` ожидания — позиции как ССЫЛКИ (тег + имя папки). У LxBox
/// позиция — тег конфига: у члена папки это тег с префиксом папки. Раннер
/// находит, в какой узел состояния позиция попадает, и сверяет пару
/// «сырой тег + папка»: перепись `folder_id` по карте id видна именно так.
/// Канон при этом сверяется с сырыми тегами — так его пишет корпус.
void _checkChains(_State state, Map<String, dynamic> expected) {
  final wantChains =
      ((expected['chains'] as List?) ?? const []).cast<Map<String, dynamic>>();
  if (wantChains.isEmpty) return;
  expect(state.chains, hasLength(wantChains.length),
      reason: 'число цепочек: пропущенная merge\'ем запись не должна '
          'материализоваться второй копией');
  final byTag = {for (final c in state.chains) c.tag: c};
  for (final want in wantChains) {
    final tag = want['tag'] as String;
    final got = byTag[tag];
    expect(got, isNotNull, reason: 'цепочка $tag не создана импортом');
    // §405 — та же указательная семантика, что у `directions[]`.
    final wantLabel = want['label'];
    if (wantLabel is String) {
      expect(got!.label, wantLabel, reason: '$tag: имя');
    }
    // enabled — УКАЗАТЕЛЬНАЯ семантика (контракт 0.7.1): отсутствие ключа в
    // ожиданиях = «не проверяем», НЕ «ожидаем false».
    final wantEnabled = want['enabled'];
    if (wantEnabled is bool) {
      expect(got!.enabled, wantEnabled,
          reason: '$tag: enabled — отсутствие ключа в записи файла обязано '
              'читаться как true, явный false — как false');
    }
    final canon = _canonOf(got!);
    final wantHops = (want['hops'] as List?)?.cast<Map<String, dynamic>>();
    if (wantHops != null) {
      final resolved = [for (final h in got.hops) _resolveHop(h, state.lists)];
      expect(
        [for (final r in resolved) r.view],
        [for (final w in wantHops) _wantLinkView(w)],
        reason: '$tag: позиции как ссылки (контейнер/тег)',
      );
      canon['hops'] = [for (final r in resolved) r.tag];
    }
    expect(canon, _deepEqualsJson(want['chain']),
        reason: '$tag: канон цепочки искажён');
  }
}

/// В какой узел состояния попадает ссылка модели (тег конфига): член папки
/// (`folder:<имя>/<сырой тег>`), узел подписки
/// (`subscription:<url>/<сырой тег>`), иначе корневая ссылка (`/<тег>`):
/// корневой узел, Направление,
/// цепочка, служебный тег или тег, которого нет.
({String tag, String view}) _resolveHop(String hop, List<ServerList> lists) {
  for (final l in lists) {
    switch (l) {
      case FolderServers():
        for (final m in l.members) {
          final bare = m.node?.tag;
          if (bare != null && TagResolver.displayTag(l.tagPrefix, bare) == hop) {
            return (tag: bare, view: 'folder:${l.name}/$bare');
          }
        }
      case SubscriptionServers():
        for (final n in l.nodes) {
          if (TagResolver.displayTag(l.tagPrefix, n.tag) == hop) {
            return (tag: n.tag, view: 'subscription:${l.url}/${n.tag}');
          }
        }
      case UserServer():
        break;
    }
  }
  return (tag: hop, view: '/$hop');
}

/// Ссылка ожидания (`README.md` корпуса, «Ссылка в ожиданиях») в той же
/// строковой форме, что [_resolveHop]. `folder: ""` — корневая ссылка
/// (запись ожиданий до NodeLink).
String _wantLinkView(Map<String, dynamic> w) {
  final tag = w['tag'];
  final folder = w['folder'];
  if (folder is String && folder.isNotEmpty) return 'folder:$folder/$tag';
  final subscription = w['subscription'];
  if (subscription is String) return 'subscription:$subscription/$tag';
  final folderId = w['folder_id'];
  if (folderId is String) return 'folder_id:$folderId/$tag';
  return '/$tag';
}

/// `detours` — личный detour узлов: тег носителя (корневой узел — его тег,
/// член папки — сырой тег) → ссылка. Карта исчерпывающая: detour у узла,
/// которого в ожиданиях нет, — расхождение.
void _checkDetours(_State state, Map<String, dynamic> expected) {
  final want = (expected['detours'] as Map?)?.cast<String, dynamic>();
  if (want == null) return;
  final got = <String, String>{
    for (final l in state.lists)
      if (l is UserServer && l.detourPolicy.overrideDetour.isNotEmpty)
        l.name: _resolveHop(l.detourPolicy.overrideDetour, state.lists).view,
    for (final l in state.lists)
      if (l is FolderServers)
        for (final m in l.members)
          if (m.detour.isNotEmpty && m.node != null)
            m.node!.tag: _resolveHop(m.detour, state.lists).view,
  };
  expect(got, {
    for (final e in want.entries)
      e.key: _wantLinkView((e.value as Map).cast<String, dynamic>()),
  }, reason: 'detour узлов: носители и ссылки');
}

/// §401 / контракт 0.12 — ПАПКА: ожидание — карта {имя папки → теги членов}
/// в порядке; проверяется и состав, и то, что запись без папки в папку не
/// затесалась. Состав читается из СОСТОЯНИЯ после слияния (§407).
///
/// §438 — `folder_ids`: имя → `id` папки после импорта. Совпавшая по `id`
/// папка держит ЛОКАЛЬНЫЙ id — по нему видно, какая ступень слияния
/// сработала (BACKUP.md §9 п. 3).
void _checkFolders(_State state, Map<String, dynamic> expected) {
  final wantFolders = (expected['folders'] as Map?)?.cast<String, dynamic>();
  if (wantFolders != null) {
    final gotFolders = <String, List<String>>{
      for (final l in state.lists)
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
  final wantIds = (expected['folder_ids'] as Map?)?.cast<String, dynamic>();
  if (wantIds != null) {
    final gotIds = <String, String>{
      for (final l in state.lists)
        if (l is FolderServers) l.name: l.id,
    };
    for (final entry in wantIds.entries) {
      expect(gotIds[entry.key], entry.value,
          reason: 'папка ${entry.key}: id после импорта (ступень слияния)');
    }
  }
}

/// §407 (D-095, BACKUP.md §9 п.1) — ПОДПИСКИ после слияния. Ожидание
/// ИСЧЕРПЫВАЮЩЕЕ: подписка, которой в нём нет, — либо не оставленная
/// локальная, либо задвоенная.
///
/// `postfix` у LxBox поля не имеет вовсе (тег источника здесь только
/// префикс), поэтому сверяется с пустой строкой: ожидание с постфиксом
/// требует override стороны.
void _checkSubscriptions(_State state, Map<String, dynamic> expected) {
  final wantSubs = (expected['subscriptions'] as Map?)?.cast<String, dynamic>();
  if (wantSubs == null) return;
  final gotSubs = <String, SubscriptionServers>{
    for (final l in state.lists)
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
      // Состав локальной подписки в файл не едет и потеряться на слиянии не
      // вправе.
      expect([for (final n in got.nodes) n.tag], wantNodes,
          reason: '${entry.key}: состав узлов пережил слияние');
    }
    final wantPending = (want['pending_disabled'] as List?)?.cast<String>();
    if (wantPending != null) {
      // Объединение двух множеств отметок: порядок в нём смысла не несёт.
      expect(got.disabledHashes.keys.toList()..sort(),
          wantPending.toList()..sort(),
          reason: '${entry.key}: отметки выключения ОБЪЕДИНЯЮТСЯ, '
              'а не замещаются файлом');
    }
  }
}

/// §438 — DNS-секция состояния: серверы исчерпывающим списком (вид, тег или
/// ссылка, включённость, тело deep-equal), число правил и все три скаляра.
/// «Тело едет байт в байт» — свойство одного кодека; у LxBox оно идёт через
/// свой декодер и хранилище, и видно только здесь.
void _checkDns(_State state, Map<String, dynamic> expected) {
  final want = (expected['dns'] as Map?)?.cast<String, dynamic>();
  if (want == null) return;
  final wantServers =
      ((want['servers'] as List?) ?? const []).cast<Map<String, dynamic>>();
  expect(state.dnsServers, hasLength(wantServers.length),
      reason: 'число DNS-серверов');
  for (var i = 0; i < wantServers.length; i++) {
    // Запись хранения — та же форма, что запись файла: `user`/`preset`/
    // `template`, тег или `ref`, тело без `tag`.
    final got = dnsServerToRecord(state.dnsServers[i]);
    final w = wantServers[i];
    expect(got['kind'], w['kind'], reason: 'DNS-сервер #$i: вид');
    expect(got['tag'] ?? '', w['tag'] ?? '', reason: 'DNS-сервер #$i: тег');
    expect(got['ref'] ?? '', w['ref'] ?? '', reason: 'DNS-сервер #$i: ссылка');
    if (w['enabled'] is bool) {
      expect(got['enabled'], w['enabled'], reason: 'DNS-сервер #$i: enabled');
    }
    if (w['body'] != null) {
      expect(got['body'], _deepEqualsJson(w['body']),
          reason: 'DNS-сервер #$i: тело');
    }
  }
  if (want['rules'] is num) {
    expect(state.dnsRules, hasLength((want['rules'] as num).toInt()),
        reason: 'число DNS-правил');
  }
  if (want['strategy'] is String) {
    expect(state.dnsStrategy, want['strategy'], reason: 'dns.strategy');
  }
  if (want['final'] is String) {
    expect(state.dnsFinal, want['final'], reason: 'dns.final');
  }
  if (want['default_domain_resolver'] is String) {
    expect(state.dnsResolver, want['default_domain_resolver'],
        reason: 'dns.default_domain_resolver');
  }
}

/// §438 — секции узлов после импорта, по тегу носителя (корневой узел и член
/// папки). Узел с секциями, которых нет в ожиданиях, — тоже расхождение.
void _checkSections(_State state, Map<String, dynamic> expected) {
  final want = (expected['sections'] as Map?)?.cast<String, dynamic>();
  if (want == null) return;
  final have = state.sections;
  expect(have.keys.toSet(), want.keys.toSet(), reason: 'носители секций');
  for (final entry in want.entries) {
    final got = have[entry.key]!;
    final w = (entry.value as Map).cast<String, dynamic>();
    final wantRules = ((w['rules'] as List?) ?? const []).cast<Map<String, dynamic>>();
    expect([for (final r in got.rules) '${r.name}:${r.enabled}'],
        [for (final r in wantRules) '${r['name']}:${r['enabled']}'],
        reason: '${entry.key}: правила связки');
    final wantServers = (w['dns_servers'] as List?)?.cast<String>();
    if (wantServers != null) {
      expect([for (final s in got.dnsServers) s.tag], wantServers,
          reason: '${entry.key}: DNS-серверы связки');
    }
    if (w['dns_rules'] is num) {
      expect(got.dnsRules, hasLength((w['dns_rules'] as num).toInt()),
          reason: '${entry.key}: число DNS-правил связки');
    }
  }
}

/// Канон цепочки (`schema/source_chain.schema.json`) из мобильной модели —
/// ровно поля маршрута, без идентичности записи (`tag`/`label`/`enabled`),
/// которая в схеме живёт уровнем выше, и без позиции в списке источников.
Map<String, dynamic> _canonOf(SourceChain c) => c.toCanonJson();

/// Матчер структурного равенства JSON-деревьев: нечувствителен к порядку
/// ключей и НЕ схлопывает `null` (RFC 7396 — он удаляет ключ, а не значит
/// «пусто»). `equals` для вложенных Map/List этого не даёт.
Matcher _deepEqualsJson(Object? want) =>
    predicate<Object?>((got) => deepEqualsJson(got, want), 'deep-equals $want');
