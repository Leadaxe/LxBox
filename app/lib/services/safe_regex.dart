/// Безопасная компиляция пользовательского regexp: `null` вместо исключения.
///
/// Одна обвязка на весь проект — до §322 копия жила в четырёх местах
/// (`build_config`, `server_list_build`, `channel_edit_screen`,
/// `auto_group_edit_screen`), и они успели разойтись по флагам.
///
/// **Инвариант потребителей:** битый паттерн трактуется как «фильтр не задан»
/// (берём всё), а не как «не совпало ничего» — иначе опечатка в поле молча
/// вырезала бы все узлы.
library;

/// [caseSensitive] — §301: node-filter каналов регистронезависим (тот же
/// дефолт, что в поиске главного окна). Значки §322 и include/exclude групп —
/// регистрозависимы: там паттерн часто литерал (флаг, тег провайдера).
///
/// [unicode] — нужен для диапазонов вне BMP (`\u{1F1E6}` — флаги-эмодзи).
RegExp? tryCompileRegex(
  String pattern, {
  bool caseSensitive = true,
  bool unicode = false,
}) {
  if (pattern.isEmpty) return null;
  try {
    return RegExp(pattern, caseSensitive: caseSensitive, unicode: unicode);
  } on FormatException {
    return null;
  }
}
