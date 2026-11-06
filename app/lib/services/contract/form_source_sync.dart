/// §654 B2 — форма узла над текстом источника (вкладка Source правки
/// узла): тело формы — разбор текста, правка формы — новый текст. Источник
/// истины — текст; форма его не переформатирует сверх нужного: компактный
/// JSON остаётся компактным, у многострочного — прежний отступ, ключи — в
/// прежнем порядке, новые — в конец своего объекта.
library;

import 'dart:convert';

/// Тело формы из текста источника: JSON-объект узла. `null` — текст не
/// разбирается как объект (JSON с ошибкой, комментарии, ссылка, INI) или
/// это документ с `outbounds`/`endpoints`, а не тело узла: тогда форма
/// неактивна.
Map<String, dynamic>? formBodyFromSource(String text) {
  final t = text.trim();
  if (!t.startsWith('{')) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(t);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  if (decoded.containsKey('outbounds') || decoded.containsKey('endpoints')) {
    return null;
  }
  return _stringKeyed(decoded);
}

/// Текст источника [source] с телом [body] от формы. Формат — как у
/// [source]: однострочный текст пишется компактно, многострочный — с его
/// отступом (по умолчанию два пробела). `type` и `tag` берутся из прежнего
/// текста, форма их не пишет. [source] не объект — [body] с отступом в два
/// пробела.
String sourceWithFormBody(String source, Map<String, dynamic> body) {
  final before = formBodyFromSource(source);
  final out = <String, dynamic>{...body};
  if (before != null) {
    for (final k in const ['type', 'tag']) {
      if (before.containsKey(k)) {
        out[k] = before[k];
      } else {
        out.remove(k);
      }
    }
  }
  final t = source.trim();
  if (before != null && !t.contains('\n')) return jsonEncode(out);
  return JsonEncoder.withIndent(_indentOf(t)).convert(out);
}

/// Отступ многострочного JSON: пробельный префикс первой строки с ключом.
String _indentOf(String text) {
  for (final line in text.split('\n')) {
    final m = RegExp(r'^([ \t]+)"').firstMatch(line);
    if (m != null) return m.group(1)!;
  }
  return '  ';
}

Map<String, dynamic> _stringKeyed(Map m) => {
  for (final e in m.entries) '${e.key}': _deep(e.value),
};

Object? _deep(Object? v) {
  if (v is Map) return _stringKeyed(v);
  if (v is List) return [for (final e in v) _deep(e)];
  return v;
}
