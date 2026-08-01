import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:json5/json5.dart';

/// Преобразует JSON / JSON5 / JSONC-подобный текст в канонический JSON-строку для sing-box/libbox.
///
/// Используется парсер [json5Decode] (комментарии, хвостовые запятые и т.д. по спецификации JSON5).
String canonicalJsonForSingbox(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Empty input');
  }
  final dynamic parsed = _json5DecodeNormalized(trimmed);
  return jsonEncode(_toJsonEncodable(parsed));
}

/// §333 — json5 на синтакс-ошибке бросает свой `SyntaxException`
/// (implements Exception, НЕ FormatException, и не экспортирован из пакета).
/// До нормализации он пролетал мимо `on FormatException` у вызывающих —
/// Save битого JSON5 падал unhandled вместо показа ошибки. Message
/// сохраняем: там уже есть координаты («… at line:col»).
dynamic _json5DecodeNormalized(String text) {
  try {
    return json5Decode(text);
  } on FormatException {
    rethrow;
  } on Exception catch (e) {
    String msg;
    try {
      msg = (e as dynamic).message as String;
    } catch (_) {
      msg = e.toString();
    }
    throw FormatException(msg);
  }
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

// §333 — off-main-thread версии для больших конфигов (сотни КБ json5-парса
// фризят UI). Sync-версии выше остаются для мелких вызовов и тестов.

Future<String> prettyJsonForDisplayAsync(String raw) =>
    compute(prettyJsonForDisplay, raw);

/// Ошибка парса пересекает границу изолята как plain message, а не как
/// FormatException: json5 кладёт в [FormatException.source] весь входной
/// текст — гонять сотни КБ между изолятами и держать их в state незачем.
({String? result, String? error}) _canonicalEntry(String text) {
  try {
    return (result: canonicalJsonForSingbox(text), error: null);
  } on FormatException catch (e) {
    return (result: null, error: e.message);
  }
}

/// Как [canonicalJsonForSingbox], но парс в изоляте. Контракт тот же:
/// бросает [FormatException] с message при невалидном входе.
Future<String> canonicalJsonForSingboxAsync(String text) async {
  final r = await compute(_canonicalEntry, text);
  if (r.error != null) throw FormatException(r.error!);
  return r.result!;
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
