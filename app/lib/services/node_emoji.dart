import 'dart:convert';

import '../models/node_spec.dart';

/// §090 G2b — эмодзи-теги серверов.
///
/// Палитра ручного пикера + дефолтный эмодзи по протоколу/серверу +
/// вставка эмодзи в name-часть `rawBody` (UserServer персистит только
/// rawBody, nodes ре-деривятся из него — поэтому эмодзи кладём именно туда).

/// Палитра ручного эмодзи-пикера (node_settings + форма создания).
const List<String> kEmojiPalette = [
  '🏠', '⚡', '🚀', '🔁', '⚙', '⭐', '🌍', '🔒',
];

/// Эмодзи: Extended_Pictographic ИЛИ пара Regional_Indicator (флаги).
/// Совпадает с `NodeFilter` emoji-regex (§048).
final RegExp _emojiRe = RegExp(
  r'(\p{Regional_Indicator}\p{Regional_Indicator}|\p{Extended_Pictographic})',
  unicode: true,
);

/// True если в строке есть хоть один эмодзи.
bool hasEmoji(String s) => _emojiRe.hasMatch(s);

/// Дефолтный эмодзи по серверу/протоколу (приоритет сверху вниз):
/// локальный → WireGuard → UDP/QUIC → TCP (fallback).
String defaultEmojiFor(NodeSpec node) {
  final server = node.server.trim().toLowerCase();
  if (server == '127.0.0.1' || server == 'localhost' || server == '::1') {
    return '🔁';
  }
  if (node is WireguardSpec) return '🏠';
  if (node is Hysteria2Spec || node is TuicSpec) return '🚀';
  return '⚡';
}

/// Если в теге ноды НЕТ эмодзи — вернуть `rawBody` с дефолтным эмодзи в
/// name-части; иначе вернуть `rawBody` как есть. Точка вызова — создание
/// UserServer (paste / wizard / SOCKS-форма).
String withDefaultEmoji(String rawBody, NodeSpec node) {
  if (hasEmoji(node.tag)) return rawBody;
  return prependEmojiToRawBody(rawBody, defaultEmojiFor(node));
}

/// Префиксует `emoji` к name-части `rawBody`, не дублируя если эмодзи там уже
/// есть. Поддерживает JSON-outbound (поле `tag`) и URI (`#fragment`).
String prependEmojiToRawBody(String rawBody, String emoji) {
  final trimmed = rawBody.trim();
  if (trimmed.isEmpty) return rawBody;
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    return _prependToJsonTag(trimmed, emoji) ?? rawBody;
  }
  return _prependToUriFragment(trimmed, emoji);
}

String? _prependToJsonTag(String json, String emoji) {
  try {
    final parsed = jsonDecode(json);
    final map = parsed is List
        ? (parsed.isNotEmpty ? parsed.first : null)
        : parsed;
    if (map is! Map<String, dynamic>) return null;
    final cur = (map['tag'] as String?) ?? '';
    if (hasEmoji(cur)) return json;
    map['tag'] = cur.isEmpty ? emoji : '$emoji $cur';
    if (parsed is List) {
      parsed[0] = map;
      return jsonEncode(parsed);
    }
    return jsonEncode(map);
  } catch (_) {
    return null;
  }
}

String _prependToUriFragment(String uri, String emoji) {
  final idx = uri.indexOf('#');
  if (idx < 0) {
    // нет имени → добавляем фрагмент с одним эмодзи.
    return '$uri#${Uri.encodeComponent(emoji)}';
  }
  final frag = uri.substring(idx + 1);
  // Декодируем текущий фрагмент чтобы проверить наличие эмодзи; если есть —
  // не трогаем.
  String decoded;
  try {
    decoded = Uri.decodeComponent(frag);
  } catch (_) {
    decoded = frag;
  }
  if (hasEmoji(decoded)) return uri;
  final base = uri.substring(0, idx + 1); // включая '#'
  return '$base${Uri.encodeComponent('$emoji ')}$frag';
}
