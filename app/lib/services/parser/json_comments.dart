/// §585 — комментарии `//` и `/* */` во вставленном sing-box JSON;
/// §686 п.11 — и `#` до конца строки, как у ядра (sing `contextjson`,
/// «JSONC comments by default», `stateBeginComment` в `scanner.go`).
///
/// Узел, написанный руками, часто несёт пометки («// United States Central»).
/// Строгий `jsonDecode` на них падает, и вставка отвечала «не распознано».
/// В источник записи пишется текст БЕЗ комментариев: иначе он не разбирается
/// как JSON-объект, и тело не становится авторским (`verbatimBodyOf`).
///
/// Снимаются только комментарии: прочие байты текста остаются как были
/// (пробелы в конце строки перед `//` и `#` тоже снимаются). Внутри строковых
/// литералов `//`, `/*` и `#` не трогаются (`"https://…"`, `"vless://…#Name"`).
/// `#` не переписывается в `//`: на диск JSON с комментариями не попадает,
/// а набранный текст живёт только в редакторе.
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
