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
};

/// Ключи секции (`mappers.<kind>`), `PRIMITIVES.md` §0.1.
const Set<String> _mapperKeys = {
  'detect', 'body_source', 'forms', 'userinfo', 'label', 'params', 'include',
  'scheme_sets', 'type_synonyms', 'defaults', 'unknown_key', 'emit',
  'ini_dialect', 'impl',
};

const Set<String> _bodySources = {'uri', 'singbox', 'xray', 'wgconf', 'amnezia'};
const Set<String> _types = {
  'string', 'int', 'bool', 'bool_spelled', 'duration', 'base64', 'list',
  'object',
};

List<File> _sections() {
  final dir = Directory(_draftRoot);
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
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

      test('корень несёт mappers и ничего постороннего', () {
        expect(doc.keys.where((k) => !k.startsWith('_')), contains('mappers'));
        final mappers = doc['mappers'];
        expect(mappers, isA<Map<String, dynamic>>());
        for (final kind in (mappers as Map).keys) {
          expect(const {'uri', 'xray', 'singbox', 'conf'}, contains(kind),
              reason: 'вид источника "$kind" вне набора грамматики');
        }
      });

      test('секция: только замороженные ключи, body_source из набора', () {
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
        final mappers = (doc['mappers'] as Map).cast<String, dynamic>();
        for (final e in mappers.entries) {
          final sec = (e.value as Map).cast<String, dynamic>();
          final params = (sec['params'] as Map?)?.cast<String, dynamic>() ?? {};
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
          expect(defaults, 1,
              reason: '${e.key}: веток default обязана быть ровно одна, '
                  'а их $defaults (линтер §0.2)');
        }
      });

      test('extract: регулярка компилируется, группы покрыты into', () {
        final mappers = (doc['mappers'] as Map).cast<String, dynamic>();
        for (final e in mappers.entries) {
          final sec = (e.value as Map).cast<String, dynamic>();
          final params = (sec['params'] as Map?)?.cast<String, dynamic>() ?? {};
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
