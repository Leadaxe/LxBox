import 'dart:convert';

import 'uri_utils.dart';

/// Результат декодирования тела подписки (§3.2 спеки 026).
/// Sealed — парсер делает exhaustive switch по результату.
sealed class DecodedBody {
  const DecodedBody();
}

final class UriLines extends DecodedBody {
  final List<String> lines;
  final int skippedComments;
  const UriLines(this.lines, this.skippedComments);
}

final class IniConfig extends DecodedBody {
  final String text;
  const IniConfig(this.text);
}

final class JsonConfig extends DecodedBody {
  final Object value;
  final JsonFlavor flavor;
  const JsonConfig(this.value, this.flavor);
}

final class DecodeFailure extends DecodedBody {
  final String reason;
  final String? sample;
  const DecodeFailure(this.reason, [this.sample]);
}

enum JsonFlavor { xrayArray, singboxOutbound, clashYaml, unknown }

/// Декодирует body подписки. Не throws.
///
/// Алгоритм:
/// 1. Пробуем base64 (все варианты). Успех + валидный UTF-8 → заменяем body.
/// 2. Trim начинается с `{` / `[` → `jsonDecode` + определяем flavor.
/// 3. Первая непустая строка `[Interface]` → IniConfig.
/// 4. Иначе — разбить на строки, выкинуть пустые и комментарии.
/// 5. Пусто → DecodeFailure.
DecodedBody decode(String body) {
  final original = body.trimRight();
  if (original.isEmpty) return const DecodeFailure('empty body');

  // Step 1: base64 attempt. Только если body выглядит как base64 (буквы/+/=//).
  final trimmedNoWs = original.replaceAll(RegExp(r'\s+'), '');
  if (_looksLikeBase64(trimmedNoWs)) {
    final bytes = decodeBase64Safe(trimmedNoWs);
    if (bytes != null && _isLikelyUtf8(bytes)) {
      final decoded = utf8Lossy(bytes).trim();
      if (decoded.isNotEmpty && _isPlausiblePayload(decoded)) {
        return _classifyPlain(decoded);
      }
    }
  }

  return _classifyPlain(original);
}

DecodedBody _classifyPlain(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return const DecodeFailure('empty after decode');

  // JSON branch
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      final value = jsonDecode(trimmed);
      return JsonConfig(value, _detectFlavor(value));
    } catch (_) {
      // Fall through to URI-lines detection.
    }
  }

  // INI branch
  if (_firstNonCommentLine(trimmed).trim().toLowerCase() == '[interface]' &&
      trimmed.contains('[Peer]')) {
    return IniConfig(trimmed);
  }

  // URI lines
  final lines = <String>[];
  var skipped = 0;
  for (final raw in trimmed.split(RegExp(r'\r?\n'))) {
    final l = raw.trim();
    if (l.isEmpty) continue;
    if (l.startsWith('#') || l.startsWith('//') || l.startsWith(';')) {
      skipped++;
      continue;
    }
    lines.add(l);
  }
  if (lines.isEmpty) {
    return DecodeFailure('no parseable content', trimmed.substring(0, trimmed.length.clamp(0, 80)));
  }
  return UriLines(lines, skipped);
}

bool _looksLikeBase64(String s) {
  if (s.length < 16) return false;
  final re = RegExp(r'^[A-Za-z0-9+/_=\-]+$');
  return re.hasMatch(s);
}

bool _isLikelyUtf8(List<int> bytes) {
  try {
    final s = utf8.decode(bytes);
    // Если > 20% управляющих байтов — скорее всего бинарь.
    var ctrl = 0;
    for (final r in s.runes) {
      if (r < 0x09 || (r > 0x0D && r < 0x20)) ctrl++;
    }
    return ctrl < (s.length * 0.2);
  } catch (_) {
    return false;
  }
}

bool _isPlausiblePayload(String s) {
  return s.contains('://') ||
      s.trimLeft().startsWith('{') ||
      s.trimLeft().startsWith('[') ||
      s.contains('[Interface]');
}

String _firstNonCommentLine(String s) {
  for (final raw in s.split(RegExp(r'\r?\n'))) {
    final l = raw.trim();
    if (l.isEmpty) continue;
    if (l.startsWith('#') || l.startsWith('//') || l.startsWith(';')) continue;
    return l;
  }
  return '';
}

JsonFlavor _detectFlavor(Object v) {
  if (v is List && v.isNotEmpty) {
    final first = v.first;
    if (first is Map && first['outbounds'] is List) {
      return JsonFlavor.xrayArray;
    }
    return JsonFlavor.unknown;
  }
  if (v is Map) {
    if (v['type'] is String) return JsonFlavor.singboxOutbound;
    if (v['proxies'] is List) return JsonFlavor.clashYaml;
  }
  return JsonFlavor.unknown;
}
