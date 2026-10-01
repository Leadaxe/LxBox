import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// §533 / контракт 1.1.53 — **ОВЕРЛЕЙ ОБЯЗАН НЕСТИ ID ДЕЛЬТЫ.**
///
/// Правило, из которого выросла волна (TASKS_LXBOX §49): «оверлей — это
/// ЗАЯВКА НА ДЕЛЬТУ, а не способ жить иначе». Запись `contract_draft` без ID
/// — красный тест у нас, ID без записи в `DELTAS.md` — красный у лаунчера.
/// Так единым реестром расхождений становится DELTAS, а не память.
///
/// Ревизия зеркала 24.09.2026 показала, чем кончается отсутствие такого
/// гарда: файлы реестра доезжали байт в байт, а 27 файлов оверлеев жили
/// рядом, и ни синк, ни lock-проверка их не видели. Часть отступлений к тому
/// моменту была СТАРШЕ реестра (xhttp `sessionPlacement` — с 1.1.50), то есть
/// компенсировала дыру, которой давно не было.
///
/// **Что проверяется здесь и что — у лаунчера.** `DELTAS.md` в зеркало LxBox
/// не едет (в git лежит только `registry/**` и `docs/generated/**`), и читать
/// его из соседнего репозитория на CI нельзя — там его нет. Поэтому здесь
/// проверяются НАЛИЧИЕ и ФОРМА ID; существование строки под этим ID в
/// `DELTAS.md` судит раннер лаунчера, которому файл свой.
void main() {
  const root = 'assets/contract_draft';

  /// Ключ с ID. Взят с `_`-префиксом: набор ключей ЗАПИСИ заморожен
  /// (`mapper_sections_draft_test`), и всё, что не является грамматикой,
  /// объявляется именем с подчёркиванием — тем же правилом, что `_why`.
  const idKey = '_delta_id';

  /// Форма ID: `D133-<номер>` / `D133-E<номер>` / `D133-C<номер>` — дельты
  /// общего реестра расхождений; `D-<цифры>` — ранняя нумерация SPEC 103;
  /// `D533-<имя>` — отступление, заявленное ЭТОЙ волной и ещё не получившее
  /// номера в DELTAS (имя обязано быть говорящим, а не порядковым).
  final idForm = RegExp(r'^(D133-(E|C)?\d+|D-\d+|D533-[a-z0-9-]+)$');

  /// Записи оверлея: у секции — `params`, `unknown_key`, `emit`; у общего
  /// блока — записи `blocks.<диалект>` (иногда сгруппированные по транспорту).
  /// Возвращает пары «адрес записи → карта записи».
  List<(String, Map<String, dynamic>)> entriesOf(
      String file, Map<String, dynamic> doc) {
    final out = <(String, Map<String, dynamic>)>[];

    void addEntry(String path, Object? v) {
      if (v is Map<String, dynamic>) out.add((path, v));
    }

    final mappers = doc['mappers'];
    if (mappers is Map) {
      for (final MapEntry(key: dialect, value: sec) in mappers.entries) {
        if (sec is! Map) continue;
        for (final MapEntry(key: k, value: v) in sec.entries) {
          if (k.toString().startsWith('_')) continue;
          if (k == 'params') {
            if (v is Map) {
              for (final p in v.entries) {
                addEntry('mappers.$dialect.params.${p.key}', p.value);
              }
            }
          } else {
            // `emit` и `unknown_key` — записи целиком: отступление объявляет
            // весь ключ, и ID живёт на нём, а не на каждом его поле.
            addEntry('mappers.$dialect.$k', v);
          }
        }
      }
    }

    final blocks = doc['blocks'];
    if (blocks is Map) {
      for (final MapEntry(key: dialect, value: table) in blocks.entries) {
        if (table is! Map) continue;
        for (final MapEntry(key: name, value: v) in table.entries) {
          if (name == 'note' || name.toString().startsWith('_')) continue;
          if (v is! Map) continue;
          final m = v.cast<String, dynamic>();
          // Группа записей (`ws`, `xhttp`) — у неё `source` нет, а члены и
          // есть записи.
          if (!m.containsKey('source') && !m.containsKey(idKey)) {
            for (final g in m.entries) {
              if (g.key == 'note' || g.key.startsWith('_')) continue;
              addEntry('blocks.$dialect.$name.${g.key}', g.value);
            }
            continue;
          }
          addEntry('blocks.$dialect.$name', m);
        }
      }
    }
    return out;
  }

  test('каждая запись contract_draft несёт ID дельты', () {
    final dir = Directory(root);
    expect(dir.existsSync(), isTrue, reason: 'нет каталога $root');

    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final problems = <String>[];
    var checked = 0;

    for (final f in files) {
      final doc =
          (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
      for (final (path, entry) in entriesOf(f.path, doc)) {
        checked++;
        final id = entry[idKey];
        if (id == null) {
          problems.add('${f.path}: $path — нет "$idKey". Оверлей это ЗАЯВКА '
              'НА ДЕЛЬТУ: назовите её ID из DELTAS.md, иначе отступление '
              'живёт молча и протухает незаметно');
          continue;
        }
        if (id is! String || !idForm.hasMatch(id)) {
          problems.add('${f.path}: $path — "$idKey" = "$id" не той формы '
              '(ждём D133-<n> / D133-E<n> / D133-C<n> / D-<n> / '
              'D533-<имя>)');
        }
      }
    }

    // Порог: набор не должен «схлопнуться» молча. Оверлеи снимаются волнами,
    // и падение до нуля законно — но тогда падает и этот тест, и снятие
    // становится видимым решением, а не тихим исчезновением проверки.
    expect(checked, greaterThan(0),
        reason: 'в $root не нашлось ни одной записи — проверять нечего. '
            'Если оверлеев действительно не осталось, удалите и этот тест '
            'вместе с каталогом');

    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
