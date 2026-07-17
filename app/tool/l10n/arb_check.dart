import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'src/check_common.dart';

// §279 (спека §9.2) — проверки ARB-каталога.
//
// 1. Равенство наборов плейсхолдеров en↔ru по каждому общему ключу — fail
//    при расхождении. Наборы извлекаются мини-парсером ICU-сообщений
//    ({name}, {name, plural|select|selectordinal, sel{...}...}); экранирование
//    одинарными кавычками ('{') не поддерживается — в каталоге не используется.
// 2. Ключ есть в en, нет в ru — warning, под --strict fail. Обратный сирота
//    (ru-ключ вне en-шаблона) — warning: gen_l10n его молча игнорирует.
// 3. Orphan-детекция: en-ключи, не встречающиеся в lib/ (минус lib/l10n/gen/).
//    Реализация сознательно консервативная: собираются ВСЕ простые
//    идентификаторы из AST (superset реальных обращений к AppLocalizations) —
//    false-orphan почти исключён, false-live возможен при коллизии ключа с
//    обычным member-именем. Точная типовая резолюция receiver'ов — позднее
//    ужесточение (Phase 7). Warning, под --strict fail.

const String _enArb = 'lib/l10n/app_en.arb';
const String _ruArb = 'lib/l10n/app_ru.arb';

Map<String, String>? _readArb(String path, CheckReporter r) {
  final f = File(path);
  if (!f.existsSync()) {
    r.fail('$path missing');
    return null;
  }
  try {
    final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    return {
      for (final e in raw.entries)
        if (!e.key.startsWith('@') && e.value is String) e.key: e.value as String,
    };
  } catch (e) {
    r.fail('$path: invalid JSON: $e');
    return null;
  }
}

// -- мини-парсер ICU ------------------------------------------------------

final RegExp _ident = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$');
const Set<String> _branchedTypes = {'plural', 'select', 'selectordinal'};

Set<String> icuPlaceholders(String msg) {
  final out = <String>{};
  _scanText(msg, 0, msg.length, out);
  return out;
}

void _scanText(String s, int start, int end, Set<String> out) {
  var i = start;
  while (i < end) {
    if (s[i] == '{') {
      i = _parseGroup(s, i, end, out);
    } else {
      i++;
    }
  }
}

/// [open] указывает на '{'; возвращает индекс за парной '}'.
int _parseGroup(String s, int open, int end, Set<String> out) {
  var depth = 0;
  var close = open;
  for (; close < end; close++) {
    if (s[close] == '{') depth++;
    if (s[close] == '}') {
      depth--;
      if (depth == 0) break;
    }
  }
  if (close >= end) return end; // несбалансировано — дальше нечего парсить
  final inner = s.substring(open + 1, close);
  final comma = inner.indexOf(',');
  if (comma < 0) {
    if (_ident.hasMatch(inner.trim())) out.add(inner.trim());
    return close + 1;
  }
  final name = inner.substring(0, comma).trim();
  if (_ident.hasMatch(name)) out.add(name);
  final rest = inner.substring(comma + 1);
  final typeEnd = rest.indexOf(',');
  final type = (typeEnd < 0 ? rest : rest.substring(0, typeEnd)).trim();
  if (_branchedTypes.contains(type)) {
    // ветки вида `sel {message}` — плейсхолдеры внутри тел веток
    final bodyStart = open + 1 + comma + 1 + (typeEnd < 0 ? rest.length : typeEnd + 1);
    var i = bodyStart;
    while (i < close) {
      if (s[i] == '{') {
        var d = 0;
        var j = i;
        for (; j < close; j++) {
          if (s[j] == '{') d++;
          if (s[j] == '}') {
            d--;
            if (d == 0) break;
          }
        }
        if (j >= close) break;
        _scanText(s, i + 1, j, out);
        i = j + 1;
      } else {
        i++;
      }
    }
  }
  return close + 1;
}

// -- сбор идентификаторов из lib/ -----------------------------------------

class _IdentCollector extends RecursiveAstVisitor<void> {
  final Set<String> names = {};

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    names.add(node.name);
    super.visitSimpleIdentifier(node);
  }
}

void main(List<String> args) {
  ensureAppCwd();
  final strict = parseStrict(args);
  final r = CheckReporter('arb_check', strict: strict);

  final en = _readArb(_enArb, r);
  final ru = _readArb(_ruArb, r);
  if (en == null || ru == null) exit(r.finish());

  var placeholderMismatches = 0;
  for (final key in en.keys.where(ru.containsKey)) {
    final pe = icuPlaceholders(en[key]!);
    final pr = icuPlaceholders(ru[key]!);
    if (!(pe.length == pr.length && pe.containsAll(pr))) {
      placeholderMismatches++;
      r.fail('placeholder mismatch for "$key": '
          'en {${(pe.toList()..sort()).join(', ')}} vs '
          'ru {${(pr.toList()..sort()).join(', ')}}');
    }
  }

  final missing = en.keys.where((k) => !ru.containsKey(k)).toList();
  if (missing.isNotEmpty) {
    r.warn('${missing.length} key(s) untranslated in ru: '
        '${missing.take(10).join(', ')}'
        '${missing.length > 10 ? ', ... +${missing.length - 10}' : ''}');
  }
  final extra = ru.keys.where((k) => !en.containsKey(k)).toList();
  if (extra.isNotEmpty) {
    r.warn('${extra.length} ru key(s) absent from en template (dead weight): '
        '${extra.take(10).join(', ')}');
  }

  // orphans
  final collector = _IdentCollector();
  final files = dartFilesUnder('lib', excludeDirs: ['lib/l10n/gen']);
  for (final path in files) {
    final parsed = parseString(
      content: File(path).readAsStringSync(),
      path: path,
      throwIfDiagnostics: false,
    );
    parsed.unit.accept(collector);
  }
  final orphans =
      en.keys.where((k) => !collector.names.contains(k)).toList()..sort();
  for (final k in orphans) {
    r.warn('ARB key "$k" is never referenced under lib/ '
        '(conservative identifier scan)');
  }

  exit(r.finish(extraRows: [
    MapEntry('en keys', '${en.length}'),
    MapEntry('ru keys', '${ru.length}'),
    MapEntry('placeholder mismatches', '$placeholderMismatches'),
    MapEntry('untranslated', '${missing.length}'),
    MapEntry('orphans', '${orphans.length}'),
    MapEntry('dart files scanned', '${files.length}'),
  ]));
}
