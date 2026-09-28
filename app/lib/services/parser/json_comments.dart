/// §585 — комментарии `//` и `/* */` во вставленном sing-box JSON.
///
/// Узел, написанный руками, часто несёт пометки («// United States Central»).
/// Строгий `jsonDecode` на них падает, и вставка отвечала «не распознано».
/// В источник записи пишется текст БЕЗ комментариев: иначе он не разбирается
/// как JSON-объект, и тело не становится авторским (`verbatimBodyOf`).
///
/// Снимаются только комментарии: прочие байты текста остаются как были
/// (пробелы в конце строки перед `//` тоже снимаются). Внутри строковых
/// литералов `//` и `/*` не трогаются (`"https://…"`).
library;

import 'dart:convert';

/// Текст без комментариев, когда выполнены все условия: (1) текст начинается
/// с `{` или `[`; (2) строгий JSON-разбор исходного текста падает; (3) в
/// тексте вне строк есть комментарий; (4) текст без комментариев — строгий
/// JSON. Иначе `null`: вызывающий берёт исходный текст как есть.
String? uncommentedJson(String text) {
  final head = text.trimLeft();
  if (!head.startsWith('{') && !head.startsWith('[')) return null;
  if (_isJson(text)) return null;
  final stripped = stripJsonComments(text);
  if (stripped == null || !_isJson(stripped)) return null;
  return stripped;
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
String? stripJsonComments(String text) {
  final out = StringBuffer();
  var found = false;
  var inString = false;
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (inString) {
      out.write(c);
      if (c == r'\' && i + 1 < text.length) {
        out.write(text[i + 1]);
        i += 2;
        continue;
      }
      if (c == '"') inString = false;
      i++;
      continue;
    }
    if (c == '"') {
      inString = true;
      out.write(c);
      i++;
      continue;
    }
    final next = i + 1 < text.length ? text[i + 1] : '';
    if (c == '/' && next == '/') {
      found = true;
      _trimTrailingBlanks(out);
      i = text.indexOf('\n', i);
      if (i < 0) break;
      continue;
    }
    if (c == '/' && next == '*') {
      found = true;
      final end = text.indexOf('*/', i + 2);
      i = end < 0 ? text.length : end + 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return found ? out.toString() : null;
}

/// Пробелы и табы в конце буфера (перед снятым `//`).
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
