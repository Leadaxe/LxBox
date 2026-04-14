import 'dart:convert';

import 'package:json5/json5.dart';

/// Преобразует JSON / JSON5 / JSONC-подобный текст в канонический JSON-строку для sing-box/libbox.
///
/// Используется парсер [json5Decode] (комментарии, хвостовые запятые и т.д. по спецификации JSON5).
String canonicalJsonForSingbox(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Empty input');
  }
  final dynamic parsed = json5Decode(trimmed);
  return jsonEncode(_toJsonEncodable(parsed));
}

/// Форматирует JSON / JSON5 / JSONC с отступами для отображения в редакторе.
/// При ошибке парсинга возвращает исходную строку as-is.
String prettyJsonForDisplay(String raw) {
  try {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return raw;
    final dynamic parsed = json5Decode(trimmed);
    return const JsonEncoder.withIndent('  ').convert(_toJsonEncodable(parsed));
  } catch (_) {
    return raw;
  }
}

dynamic _toJsonEncodable(dynamic value) {
  if (value == null || value is num || value is String || value is bool) {
    return value;
  }
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), _toJsonEncodable(v)));
  }
  if (value is List) {
    return value.map(_toJsonEncodable).toList();
  }
  throw FormatException('Unsupported type: ${value.runtimeType}');
}
