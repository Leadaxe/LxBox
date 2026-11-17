/// §585 — комментарии `//` и `/* */` во вставленном sing-box JSON;
/// §686 п.11 — и `#` до конца строки, как у ядра (sing `contextjson`,
/// «JSONC comments by default», `stateBeginComment` в `scanner.go`).
///
/// Узел, написанный руками, часто несёт пометки. Строгий `jsonDecode` на них
/// падает, и вставка отвечала «не распознано».
///
/// §741 (контракт 1.1.172, BACKUP.md §2 `origin`, D-149) — комментарии
/// ХРАНЯТСЯ: `origin.raw` видов `singbox` / `xray` — текст как набран, с
/// пометками автора («// United States Central»). Снимаются они на ЧТЕНИИ:
/// каждый, кто разбирает JSON-исходник (движок `decode`, классификация
/// входа, идентичность и дедуп бэкапа, правка тега), берёт [jsonSourceText]
/// — одну функцию «исходник → JSON». Обрезанный остаток документа (§11 п.2)
/// пересобирается без комментариев (`source_classify.dart`).
///
/// Снимаются только комментарии: прочие байты текста остаются как были
/// (пробелы в конце строки перед `//` и `#` тоже снимаются). Внутри строковых
/// литералов `//`, `/*` и `#` не трогаются (`"https://…"`, `"vless://…#Name"`,
/// пароль `"pass//not#comment/*x*/"`). Незакрытый `/*` съедает текст до
/// конца.
library;

import 'dart:convert';

/// §741 — JSON-исходник узла → текст для разбора: без комментариев, если
/// они в нём есть и без них текст — строгий JSON ([uncommentedJson]); иначе
/// [text] как есть (ссылка, `.conf`, JSON без комментариев, битый текст).
String jsonSourceText(String text) => uncommentedJson(text) ?? text;

/// Текст без комментариев, когда выполнены все условия: (1) первый значащий
/// символ — `{`, `[`, `/` или `#` (дешёвый отсев ссылок и base64); (2) в
/// тексте вне строк есть комментарий; (3) текст без комментариев начинается
/// с `{` или `[` и (4) это строгий JSON. Иначе `null`: вызывающий берёт
/// исходный текст как есть. Строгий JSON без комментариев сканер проходит,
/// ничего не найдя, — второго `jsonDecode` у него нет.
String? uncommentedJson(String text) {
  final head = text.trimLeft();
  if (head.isEmpty) return null;
  final c0 = head[0];
  if (c0 != '{' && c0 != '[' && c0 != '/' && c0 != '#') return null;
  final stripped = stripJsonComments(text);
  if (stripped == null) return null;
  final h = stripped.trimLeft();
  if (!h.startsWith('{') && !h.startsWith('[')) return null;
  if (!_isJson(stripped)) return null;
  return stripped;
}

/// §741 — тег [tag] в голое тело JSON [text] ПРАВКОЙ ТЕКСТА: комментарии и
/// форматирование остаются как набраны. Ключ `tag` верхнего уровня есть —
/// заменяется его строковое значение; нет — `"tag": …` встаёт первым ключом
/// (с переводом строки и отступом следующей строки, если после `{` идёт
/// перевод строки). `null` — текст не объект, объект пуст или значение `tag`
/// не строка: вызывающий пересобирает JSON сам.
String? withJsonTag(String text, String tag) {
  final enc = jsonEncode(tag);
  final open = _skipBlank(text, 0);
  if (open >= text.length || text[open] != '{') return null;
  final first = _skipBlank(text, open + 1);
  if (first >= text.length || text[first] == '}') return null;
  var depth = 0;
  var i = open;
  while (i < text.length) {
    final c = text[i];
    final next = i + 1 < text.length ? text[i + 1] : '';
    if (c == '#' || (c == '/' && (next == '/' || next == '*'))) {
      i = _skipBlank(text, i);
      continue;
    }
    if (c == '"') {
      final end = _stringEnd(text, i);
      if (end < 0) return null;
      if (depth == 1) {
        final colon = _skipBlank(text, end + 1);
        if (colon < text.length &&
            text[colon] == ':' &&
            text.substring(i, end + 1) == '"tag"') {
          final v = _skipBlank(text, colon + 1);
          if (v >= text.length || text[v] != '"') return null;
          final vEnd = _stringEnd(text, v);
          if (vEnd < 0) return null;
          return text.replaceRange(v, vEnd + 1, enc);
        }
      }
      i = end + 1;
      continue;
    }
    if (c == '{' || c == '[') depth++;
    if (c == '}' || c == ']') depth--;
    i++;
  }
  // Ключа нет — первым ключом объекта.
  final after = open + 1;
  final nl = text.startsWith('\r\n', after)
      ? '\r\n'
      : text.startsWith('\n', after)
          ? '\n'
          : null;
  if (nl == null) return text.replaceRange(after, after, '"tag": $enc, ');
  final lineStart = after + nl.length;
  var j = lineStart;
  while (j < text.length && (text[j] == ' ' || text[j] == '\t')) {
    j++;
  }
  final indent = text.substring(lineStart, j);
  return text.replaceRange(after, after, '$nl$indent"tag": $enc,');
}

/// Позиция закрывающей `"` строки, открытой в [start]; `-1` — не закрыта.
int _stringEnd(String text, int start) {
  var i = start + 1;
  while (i < text.length) {
    final c = text[i];
    if (c == r'\') {
      i += 2;
      continue;
    }
    if (c == '"') return i;
    i++;
  }
  return -1;
}

/// Первый значащий символ с позиции [i]: пробелы и комментарии пропускаются.
int _skipBlank(String text, int i) {
  while (i < text.length) {
    final c = text[i];
    final next = i + 1 < text.length ? text[i + 1] : '';
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      i++;
    } else if (c == '#' || (c == '/' && next == '/')) {
      final end = text.indexOf('\n', i);
      i = end < 0 ? text.length : end;
    } else if (c == '/' && next == '*') {
      final end = text.indexOf('*/', i + 2);
      i = end < 0 ? text.length : end + 2;
    } else {
      break;
    }
  }
  return i;
}

bool _isJson(String text) {
  try {
    jsonDecode(text);
    return true;
  } on FormatException {
    return false;
  }
}

/// Снять комментарии вне строковых литералов. `null` — снимать нечего.
///
/// Один посимвольный сканер, без регулярок:
/// - строку открывают `"` и `'` (одинарные — у JSON5), закрывает только та
///   же кавычка, что открыла;
/// - внутри строки `\` берёт следующий символ парой (`\"`, `\'`, `\\`,
///   перевод строки JSON5) — пара ничего не переключает;
/// - вне строки `#` снимает всё до конца строки.
///
/// Режимы: строгий JSON (вставка, Source; [json5] = false) снимает `//`,
/// `/* */` и `#`. Перед `json5Decode` ([json5] = true) снимается только `#`:
/// `//` и `/* */` разбирает пакет `json5`, сканер переносит их как есть
/// (кавычка и `#` внутри них ничего не значат). Вне строк `#` в JSON5 не
/// бывает ни в ключе без кавычек, ни в числе, поэтому проход ничего, кроме
/// комментария, не задевает.
String? stripJsonComments(String text, {bool json5 = false}) {
  final out = StringBuffer();
  var found = false;
  String? quote;
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < text.length) {
        out.write(text[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '#') {
      found = true;
      i = _skipLineComment(text, i, out);
      continue;
    }
    final next = i + 1 < text.length ? text[i + 1] : '';
    if (c == '/' && next == '/') {
      if (json5) {
        // Комментарий JSON5 остаётся пакету `json5` — переносим как есть.
        final end = text.indexOf('\n', i);
        final stop = end < 0 ? text.length : end;
        out.write(text.substring(i, stop));
        i = stop;
        continue;
      }
      found = true;
      i = _skipLineComment(text, i, out);
      continue;
    }
    if (c == '/' && next == '*') {
      final end = text.indexOf('*/', i + 2);
      final stop = end < 0 ? text.length : end + 2;
      if (json5) {
        out.write(text.substring(i, stop));
      } else {
        found = true;
      }
      i = stop;
      continue;
    }
    out.write(c);
    i++;
  }
  return found ? out.toString() : null;
}

/// Строчный комментарий с позиции [i]: снять пробелы перед ним и вернуть
/// позицию перевода строки (сам `\n` остаётся) или конец текста.
int _skipLineComment(String text, int i, StringBuffer out) {
  _trimTrailingBlanks(out);
  final end = text.indexOf('\n', i);
  return end < 0 ? text.length : end;
}

/// Пробелы и табы в конце буфера (перед снятым `//` / `#`).
void _trimTrailingBlanks(StringBuffer out) {
  final s = out.toString();
  var end = s.length;
  while (end > 0 && (s[end - 1] == ' ' || s[end - 1] == '\t')) {
    end--;
  }
  if (end == s.length) return;
  out
    ..clear()
    ..write(s.substring(0, end));
}
