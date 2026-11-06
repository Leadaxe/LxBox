import 'dart:convert';

import 'package:characters/characters.dart';

import '../models/node_spec.dart';

/// §090 G2b — эмодзи-теги серверов.
///
/// Палитра ручного пикера + дефолтный эмодзи по протоколу/серверу +
/// вставка эмодзи в name-часть `rawBody` (UserServer персистит только
/// rawBody, nodes ре-деривятся из него — поэтому эмодзи кладём именно туда).

/// Палитра ручного эмодзи-пикера (node_settings + форма создания).
/// §090 G2b — палитра для ручного выбора эмодзи тега ([EmojiPickerButton]).
/// Базовые (сеть/статус) + VPN-транспорты: ☁️ WARP, 🎭 MASQUE, ⛈️ AWG — то,
/// что проект ставит сам ([defaultEmojiFor]).
const List<String> kEmojiPalette = [
  '🏠', '⚡', '🚀', '🔁', '⚙', '⭐', '🌍', '🔒',
  '☁️', '🎭', '⛈️', '🌀', '🛡️', '❤️',
];

/// Эмодзи: Extended_Pictographic ИЛИ пара Regional_Indicator (флаги).
/// Совпадает с `NodeFilter` emoji-regex (§048).
// Анализатор Dart 3.13 не разбирает \p{...}-классы Unicode, хотя движок
// RegExp с unicode: true их поддерживает — выражение рабочее (см. §048 и
// тесты эмодзи). Отсюда точечное подавление valid_regexps.
final RegExp _emojiRe = RegExp(
  // ignore: valid_regexps
  r'(\p{Regional_Indicator}\p{Regional_Indicator}|\p{Extended_Pictographic})',
  unicode: true,
);

/// True если в строке есть хоть один эмодзи.
bool hasEmoji(String s) => _emojiRe.hasMatch(s);

/// Дефолтный эмодзи по серверу/протоколу (приоритет сверху вниз):
/// WARP → локальный → WireGuard → MASQUE → UDP/QUIC → TCP (fallback).
String defaultEmojiFor(NodeSpec node) {
  // §025 — Cloudflare WARP: узел технически WireguardSpec, но тег ставится
  // `WARP`/`WARP+` (toWireguardUri). Распознаём по тегу ДО ветки WireguardSpec,
  // чтобы дать облако ☁️ вместо домашнего 🏠.
  final bareTag = node.tag.trim();
  if (bareTag == 'WARP' || bareTag == 'WARP+') return '🔥☁️';

  final server = node.server.trim().toLowerCase();
  if (server == '127.0.0.1' || server == 'localhost' || server == '::1') {
    return '🔁';
  }
  if (node is WireguardSpec) return '🏠';
  // §435 — Tailscale: узел tailnet, «узел сети».
  if (node is TailscaleSpec) return '🕸️';
  // §130 — MASQUE-транспорт: маска 🎭. WARP-MASQUE-узлы из визарда ставят свой
  // тег 🔥🎭 (🔥 = WARP-брендинг) и сюда не доходят (withDefaultEmoji). Эта
  // ветка — для generic masque-нод из JSON/URI с тегом без эмодзи.
  if (node is MasqueSpec) return '🎭';
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

// ---------------------------------------------------------------------------
// §647 — префикс тегов подписки из эмодзи её названия.
// ---------------------------------------------------------------------------

/// Класс графемного кластера для [emojiPrefixFromTitle].
enum _TitleCluster { emoji, text, other }

// valid_regexps подавлен по той же причине, что и у [_emojiRe]: анализатор не
// разбирает \p{...}, движок с unicode: true их поддерживает.
final RegExp _emojiPresentationRe =
    // ignore: valid_regexps
    RegExp(r'\p{Emoji_Presentation}', unicode: true);
final RegExp _extPictographicRe =
    // ignore: valid_regexps
    RegExp(r'\p{Extended_Pictographic}', unicode: true);
final RegExp _regionalPairRe =
    // ignore: valid_regexps
    RegExp(r'^\p{Regional_Indicator}\p{Regional_Indicator}', unicode: true);
final RegExp _letterOrDigitStartRe =
    // ignore: valid_regexps
    RegExp(r'^[\p{L}\p{N}]', unicode: true);

/// Максимум кластеров в группе (индекс дедупликации идёт сверх лимита).
const int _kTitlePrefixMaxClusters = 4;

/// Серия из стольких разделителей и длиннее рвёт группу.
const int _kTitlePrefixMaxGap = 3;

_TitleCluster _classifyTitleCluster(String c) {
  // Эмодзи: флаг (пара Regional Indicator), keycap (U+20E3), символ с
  // Emoji_Presentation, Extended_Pictographic с U+FE0F. ZWJ-склейки и тоны
  // кожи — один кластер, сюда приходят целиком. `©`, `™`, `★` без U+FE0F —
  // не эмодзи.
  if (_regionalPairRe.hasMatch(c) ||
      c.contains('⃣') ||
      _emojiPresentationRe.hasMatch(c) ||
      (c.contains('️') && _extPictographicRe.hasMatch(c))) {
    return _TitleCluster.emoji;
  }
  if (_letterOrDigitStartRe.hasMatch(c)) return _TitleCluster.text;
  return _TitleCluster.other;
}

/// §647 — группа эмодзи из названия подписки для `tagPrefix`.
///
/// Группа начинается с первого эмодзи-кластера и тянется вправо: эмодзи
/// подряд, а также эмодзи после серии короче [_kTitlePrefixMaxGap]
/// разделителей (пробел, `·`, `|` …). Текст, конец строки, длинная серия
/// разделителей или серия без эмодзи за ней — конец группы. Не больше
/// [_kTitlePrefixMaxClusters] кластеров; на краях разделителей не бывает.
/// Эмодзи нет — пустая строка.
String emojiPrefixFromTitle(String title) {
  final cs = title.characters.toList();
  final cls = cs.map(_classifyTitleCluster).toList();
  var i = cls.indexOf(_TitleCluster.emoji);
  if (i < 0) return '';
  final group = <String>[cs[i]];
  i++;
  while (i < cs.length) {
    if (cls[i] == _TitleCluster.emoji) {
      if (group.length + 1 > _kTitlePrefixMaxClusters) break;
      group.add(cs[i]);
      i++;
      continue;
    }
    if (cls[i] != _TitleCluster.other) break;
    var j = i;
    while (j < cs.length && cls[j] == _TitleCluster.other) {
      j++;
    }
    final gap = j - i;
    if (gap >= _kTitlePrefixMaxGap ||
        j >= cs.length ||
        cls[j] != _TitleCluster.emoji) {
      break;
    }
    // Серия вместе с эмодзи за ней не влезает в лимит — стоп на набранном
    // (хвостовые разделители в группу так и не попадают).
    if (group.length + gap + 1 > _kTitlePrefixMaxClusters) break;
    group.addAll(cs.sublist(i, j + 1));
    i = j + 1;
  }
  return group.join();
}

/// §647 — свободный вариант префикса: [candidate], если его нет среди
/// [taken], иначе первый свободный из `candidate2`, `candidate3`, …
/// (индекс без пробела, лимит кластеров на него не действует). Сравнение —
/// точное совпадение строк.
String dedupTagPrefix(String candidate, Iterable<String> taken) {
  final used = taken.toSet();
  if (!used.contains(candidate)) return candidate;
  for (var n = 2;; n++) {
    final next = '$candidate$n';
    if (!used.contains(next)) return next;
  }
}
