import 'dart:convert';

/// Безопасный UTF-8 decode — на invalid bytes возвращает null вместо throw.
String? utf8DecodeOrNull(List<int> bytes) {
  try {
    return const Utf8Decoder(allowMalformed: false).convert(bytes);
  } catch (_) {
    return null;
  }
}
