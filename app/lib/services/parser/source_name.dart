/// §456 — имя, написанное в самом тексте источника. Имя узла своего сервера
/// и члена папки — `tag` записи; текст меняет его, только когда имя в тексте
/// изменили правкой.
library;

import 'dart:convert';

import '../../models/source_dialect.dart';
import 'body_decoder.dart';
import 'json_comments.dart';
import 'parse_all.dart';
import 'source_classify.dart';

/// В тексте источника есть своё имя: фрагмент одиночной ссылки, `tag` голого
/// тела, `tag` хотя бы одного узла документа. У `wg_ini` — никогда.
bool textHasOwnName(String text, SourceDialect dialect) {
  switch (dialect) {
    case SourceDialect.wgIni:
      return false;
    case SourceDialect.uri:
      if (text.contains('\n') || !text.contains('://')) return true;
      final i = text.indexOf('#');
      return i >= 0 && text.substring(i + 1).trim().isNotEmpty;
    case SourceDialect.singbox:
    case SourceDialect.xray:
      break;
  }
  final Object? v;
  try {
    v = jsonDecode(jsonSourceText(text));
  } catch (_) {
    return false;
  }
  if (v is! Map) return false;
  bool tagged(Object? e) {
    final t = e is Map ? e['tag'] : null;
    return t is String && t.trim().isNotEmpty;
  }

  if (tagged(v)) return true;
  for (final k in nodeArrayKeysOf(dialect)) {
    final arr = v[k];
    if (arr is List && arr.any(tagged)) return true;
  }
  return false;
}

/// Имя первого узла, изменённое правкой текста [before] → [after]. `null` —
/// в новом тексте своего имени нет или оно прежнее: имя записи сохраняется.
String? nameWrittenByEdit(String before, String after) {
  final next = after.trim();
  if (!textHasOwnName(next, sourceDialectOf(next))) return null;
  final name = _firstName(next);
  return name == null || name == _firstName(before.trim()) ? null : name;
}

String? _firstName(String text) {
  if (text.isEmpty) return null;
  try {
    final nodes = parseAll(decode(text), own: true);
    return nodes.isEmpty ? null : nodes.first.tag;
  } catch (_) {
    return null;
  }
}
