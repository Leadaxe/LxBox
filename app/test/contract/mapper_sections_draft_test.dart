import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// §480 — структурная проверка черновиков секций-мапперов
/// (`assets/contract_draft/<вид источника>/<схема>.json`).
///
/// Секции — ДАННЫЕ, которые исполняет движок, и до его прихода единственная
/// защита от опечатки в них — вот эта проверка. Она намеренно НЕ повторяет
/// `registry_mapper.schema.json` лаунчера дословно: живой реестр лаунчера
/// (контракт 1.1.13, `trojan.json`) сам этой схеме не соответствует в трёх
/// местах — `impl` на `userinfo`/`forms`/`label`, `param_order` строкой
/// `"alphabetical"` и `decode_extra.plus_literal` (в замороженной таблице
/// `PRIMITIVES.md` §0.4 имя `plus_literal`, в schema.json осталось
/// `preserve_plus`). Нормативна ФОРМА ЖИВОГО РЕЕСТРА, и проверяется здесь
/// именно она.
///
/// Гейта на `app/contract` тут нет: черновики лежат в `assets/`, то есть в
/// git и в APK. Под гейтом вендоренной копии тест молча пропускался бы на CI.
const _draftRoot = 'assets/contract_draft';

/// Замороженный набор ключей записи таблицы (`params.<имя>`),
/// `PRIMITIVES.md` §0.3 + §0.4.
const Set<String> _paramKeys = {
  'source', 'maps_to', 'aliases', 'type', 'required', 'selector', 'priority',
  'merge', 'value_map', 'sets', 'implies', 'when', 'extract', 'compose',
  'list', 'split_into', 'normalize', 'decode_extra', 'default_from',
  'default_when', 'materialize_default', 'coerce', 'flatten', 'lift',
  'sort_keys', 'empty', 'on_invalid', 'on_present', 'on_item_invalid',
  'on_no_match', 'on_len_gt', 'emit_when', 'omit_default', 'implicit',
  'since', 'desc_en', 'desc_ru', 'impl',
  // §0.3 FROZEN, пропущены при составлении набора: обе пары `on_*` стоят в
  // той же строке таблицы PRIMITIVES, что `on_invalid`/`on_present`, и обе
  // исполняются движком. Реестр их пишет (`transports.uri.xhttp
  // .uplinkDataPlacement` несёт обе), поэтому запись, скопированная из
  // реестра в черновик, падала здесь на ровном месте.
  'on_when_false', 'on_implies_written',
  // §480 — ПОЧЕМУ ОТСТУПЛЕНИЕ. Поле-комментарий у записи ОВЕРЛЕЯ: оверлей
  // несёт только то, что у нас обязано вести себя иначе, и каждая такая
  // запись обязана назвать причину — иначе отступление нельзя ни снять, ни
  // передать лаунчеру. От `impl` отличается адресатом: `impl` объясняет,
  // КАК читается диалект, `_why` — ПОЧЕМУ мы разошлись с реестром.
  '_why',
  // §0.4a ДОБАВЛЕНИЕ (контракт 1.1.14): `format` — исключение «+» выводится
  // из ФОРМАТА поля, а не из списка имён. `base64*` даёт литеральный «+» на
  // всё значение, `pem` — только в base64-теле, тогда как в строках
  // `-----BEGIN …-----` «+» остаётся пробелом (D133-15).
  'format',
  // §480 W8 ДОБАВЛЕНИЕ — обратный ход. `emit_as` объявляет, КАК запись
  // сериализуется в ссылку, когда тело хранит значение не строкой
  // (`join` / `bool01` / `json` / `raw`). Реестр его не знает: он описывает
  // только чтение, а написание булева — `true` словом против `1` — свойство
  // параметра, не типа значения, и живые панели читают эти две ссылки
  // по-разному. Ключ наш, как `kind_when`, и исполняется движком
  // (`emitter.dart`, `_serializeValue`).
  'emit_as',
  // ДОБАВЛЕНИЕ (решение владельца 19.09.2026, дельта `delta480-7`) —
  // `on_empty: {code}`: код за ПУСТОЕ значение записи, узел при этом
  // ОСТАЁТСЯ. Своего места в наборе у события не было: `on_invalid` судит
  // написание значения, а пустая строка формы не нарушает и ни одной
  // проверкой типа не ловится; `required` же судит слишком строго — он
  // отбраковывает. Ключ наш, как `emit_as` и `kind_when`, и исполняется
  // движком (`interpreter.dart`, `_applyOnEmpty`). Передан лаунчеру вместе с
  // именем кода; с приходом контракта правило станет реестровым.
  'on_empty',
  // Имя кода, ОБЪЯВЛЕННОЕ вперёд реестра: того же рода пометка, что у
  // `wgconf_extra_peer_dropped` в секции `conf`. Отличается от неё тем, что
  // здесь код ВКЛЮЧЁН (`on_empty.code`), а `$code_pending` лишь называет
  // его ожидающим текстов `warnings.json` — поведение владельцем решено, и
  // ждать синка ему незачем.
  r'$code_pending',
};

/// Ключи секции (`mappers.<kind>`), `PRIMITIVES.md` §0.1.
const Set<String> _mapperKeys = {
  'detect', 'body_source', 'forms', 'userinfo', 'label', 'params', 'include',
  'scheme_sets', 'type_synonyms', 'defaults', 'unknown_key', 'emit',
  'ini_dialect', 'impl',
  // §480 — РОД УЗЛА ОТ ВХОДА. В `PRIMITIVES.md` лаунчера ключа нет: он наш,
  // заведён коммитом «род узла от входа» и исполняется движком
  // (`section.dart`, `interpreter.dart` G1). Секция объявляет им род,
  // который судит не тело, а сам вход, — иначе одна и та же запись читалась
  // бы разными родами в зависимости от формы.
  'kind_when',
};

const Set<String> _bodySources = {'uri', 'singbox', 'xray', 'wgconf', 'amnezia'};
const Set<String> _types = {
  'string', 'int', 'bool', 'bool_spelled', 'duration', 'base64', 'list',
  'object',
};

/// Файлы черновика бывают ДВУХ форм, и обе нормативны (`PRIMITIVES.md` §0.1):
///
/// - секция протокола — корень несёт `mappers.<kind>`;
/// - общий блок (`tls`, `transports`) — корень несёт `blocks.<диалект>`, и
///   его записи вмонтируются в секцию схемы через `include`.
///
/// Проверки записей одинаковы для обеих; различается только вход в дерево.
/// Файл `registry_mapper.schema.json` — это САМА JSON-схема грамматики, а не
/// секция: он лежит рядом копией, и проверять его как секцию бессмысленно.
///
/// §480 W6 — `documents.json` это ТРЕТЬЯ форма: реестр ВИДОВ ДОКУМЕНТА
/// (корень несёт `sources`). Он не секция и не общий блок — он выбирает, чем
/// читать вход, до того как секция вообще понадобится, и записей с `source`
/// в нём нет. Его форму судит свой тест (`document_registry_test.dart`), а
/// здесь он молча читался как секция и падал на отсутствующем `mappers`.
bool _isBlocks(Map<String, dynamic> doc) => doc.containsKey('blocks');

List<File> _sections() {
  final dir = Directory(_draftRoot);
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .where((f) => !f.path.endsWith('registry_mapper.schema.json'))
      .where((f) => !f.path.endsWith('documents.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// Все секции документа: у формы `mappers` — по виду источника, у формы
/// `blocks` — по диалекту, и записи там лежат либо плоско, либо группами
/// (`ws`, `http`, `$selector`). Группа — способ читать файл глазами;
/// вариантность выражена `when` у самих записей.
Map<String, Map<String, dynamic>> _sectionsOf(Map<String, dynamic> doc) {
  if (!_isBlocks(doc)) {
    return (doc['mappers'] as Map).cast<String, dynamic>().map(
          (k, v) => MapEntry(k, (v as Map).cast<String, dynamic>()),
        );
  }
  final out = <String, Map<String, dynamic>>{};
  for (final d in (doc['blocks'] as Map).entries) {
    final v = d.value;
    if (v is! Map) continue;
    final params = <String, dynamic>{};
    for (final e in v.cast<String, dynamic>().entries) {
      final ev = e.value;
      if (ev is! Map) continue;
      if (ev.containsKey('source')) {
        params[e.key] = ev;
      } else if (e.key == 'prefix' || e.key == 'strip') {
        // Именованная таблица `value_map` (`fp_dialect`) — не записи.
        continue;
      } else {
        for (final g in ev.cast<String, dynamic>().entries) {
          if (g.value is Map && (g.value as Map).containsKey('source')) {
            params['${e.key}.${g.key}'] = g.value;
          }
        }
      }
    }
    if (params.isNotEmpty) out['${d.key}'] = {'params': params};
  }
  return out;
}

void main() {
  final files = _sections();

  test('черновики секций вообще есть', () {
    expect(files, isNotEmpty,
        reason: 'в $_draftRoot не найдено ни одной секции — каталог потерян?');
  });

  for (final f in files) {
    group(f.path, () {
      late Map<String, dynamic> doc;

      setUpAll(() {
        doc = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      });

      test('корень несёт mappers либо blocks и ничего постороннего', () {
        final top = doc.keys.where((k) => !k.startsWith('_')).toSet();
        expect(top.contains('mappers') || top.contains('blocks'), isTrue,
            reason: 'корень обязан нести либо mappers (секция протокола), '
                'либо blocks (общий блок, вмонтируемый через include)');
        if (_isBlocks(doc)) return;
        for (final kind in (doc['mappers'] as Map).keys) {
          expect(const {'uri', 'xray', 'singbox', 'conf'}, contains(kind),
              reason: 'вид источника "$kind" вне набора грамматики');
        }
      });

      test('секция: только замороженные ключи, body_source из набора', () {
        // У общего блока своей секции нет: он вмонтируется в секцию схемы, и
        // `body_source` объявляет она.
        if (_isBlocks(doc)) return;
        // ОВЕРЛЕЙ несёт не секцию, а только те ключи, которые перекрывают
        // реестровые: обязательных среди них нет по определению.
        if (doc['_overlay'] == true) return;
        final mappers = (doc['mappers'] as Map).cast<String, dynamic>();
        for (final e in mappers.entries) {
          final sec = (e.value as Map).cast<String, dynamic>();
          for (final k in sec.keys) {
            if (k.startsWith('_')) continue;
            expect(_mapperKeys, contains(k),
                reason: '${e.key}: ключ секции "$k" вне грамматики');
          }
          expect(_bodySources, contains(sec['body_source']),
              reason: '${e.key}: body_source "${sec['body_source']}"');
        }
      });

      test('записи таблицы: ключи и type из замороженного набора', () {
        for (final e in _sectionsOf(doc).entries) {
          final params =
              (e.value['params'] as Map?)?.cast<String, dynamic>() ?? {};
          for (final p in params.entries) {
            final rec = (p.value as Map).cast<String, dynamic>();
            for (final k in rec.keys) {
              if (k.startsWith('_')) continue;
              expect(_paramKeys, contains(k),
                  reason: '${e.key}.${p.key}: ключ записи "$k" вне грамматики');
            }
            // `source` — ЕДИНСТВЕННЫЙ способ получить значение (§11 линтера):
            // запись без него объявлена, но не читается — тот самый дефект,
            // ради которого затеяна кампания.
            expect(rec.containsKey('source'), isTrue,
                reason: '${e.key}.${p.key}: запись без source не читается');
            final t = rec['type'];
            if (t != null) {
              expect(_types, contains(t),
                  reason: '${e.key}.${p.key}: type "$t" вне набора');
            }
          }
        }
      });

      test('формы: у каждой есть id, ровно одна ветка default', () {
        if (_isBlocks(doc)) return;
        final mappers = (doc['mappers'] as Map).cast<String, dynamic>();
        for (final e in mappers.entries) {
          final sec = (e.value as Map).cast<String, dynamic>();
          final forms = (sec['forms'] as List?) ?? const [];
          if (forms.isEmpty) continue;
          final ids = <String>{};
          var defaults = 0;
          for (final raw in forms) {
            final form = (raw as Map).cast<String, dynamic>();
            final id = form['id'];
            expect(id, isA<String>(), reason: '${e.key}: форма без id');
            expect(ids.add(id as String), isTrue,
                reason: '${e.key}: форма "$id" объявлена дважды');
            if (((form['detect'] as Map?)?['default']) == true) defaults++;
          }
          // Веток `default` не больше одной (две — неоднозначность), но и
          // ноль законен: секция с ОДНОЙ формой, у которой `detect` — guard
          // по типу полей, означает «битая запись не наша, элемент
          // пропускается». Требовать там `default` значило бы требовать
          // разбирать мусор.
          expect(defaults, lessThanOrEqualTo(1),
              reason: '${e.key}: веток default не может быть больше одной, '
                  'а их $defaults (линтер §0.2)');
          if (forms.length > 1) {
            expect(defaults, 1,
                reason: '${e.key}: у секции с несколькими формами обязана '
                    'быть ветка «всё остальное», иначе часть входов не '
                    'подойдёт ни к одной форме и узел молча исчезнет');
          }
        }
      });

      test('extract: регулярка компилируется, группы покрыты into', () {
        for (final e in _sectionsOf(doc).entries) {
          final params =
              (e.value['params'] as Map?)?.cast<String, dynamic>() ?? {};
          for (final p in params.entries) {
            final ex = ((p.value as Map)['extract'] as Map?)
                ?.cast<String, dynamic>();
            if (ex == null) continue;
            final re = ex['re'] as String;
            // Диалект — RE2 ∩ ECMAScript; в Dart именованные группы пишутся
            // (?<name>…), в реестре — (?P<name>…) ради Go. Перед компиляцией
            // приводим написание, как это будет делать загрузчик движка.
            final dartRe = re.replaceAll('(?P<', '(?<');
            expect(() => RegExp(dartRe), returnsNormally,
                reason: '${e.key}.${p.key}: extract.re не компилируется');
            final groups = RegExp(r'\(\?P?<([A-Za-z_][A-Za-z0-9_]*)>')
                .allMatches(re)
                .map((m) => m.group(1)!)
                .toSet();
            final into =
                ((ex['into'] as Map?)?.cast<String, dynamic>() ?? {}).keys.toSet();
            expect(groups.difference(into), isEmpty,
                reason: '${e.key}.${p.key}: группы extract не покрыты into — '
                    'значение уехало бы в никуда');
          }
        }
      });
    });
  }
}
