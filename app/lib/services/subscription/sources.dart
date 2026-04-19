import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/node_spec.dart';
import '../../models/subscription_meta.dart';
import '../parser/body_decoder.dart';
import '../parser/parse_all.dart';

/// Источник подписки/узлов (§3.1 спеки 026). Sealed — топ-функция `fetch`
/// делает exhaustive switch.
sealed class SubscriptionSource {
  const SubscriptionSource();
}

final class UrlSource extends SubscriptionSource {
  final String url;
  final String userAgent;
  final Duration timeout;
  const UrlSource(
    this.url, {
    // `SubscriptionParserClient` — исторический UA v1. Некоторые провайдеры
    // (Liberty и др.) выбирают формат тела по UA: Clash-клиентам отдают
    // YAML, парсерам-агентам — base64 URI-list. v2 плотно ест URI-list,
    // YAML пока не парсит — оставляем v1-поведение.
    this.userAgent = 'LxBox Android subscription client',
    // Короткий таймаут на попытку. Fetch делает 2 попытки с паузой 2с:
    // 9s + 2s + 9s ≈ 20s worst case (см. `_fetch`).
    this.timeout = const Duration(seconds: 9),
  });
}

final class FileSource extends SubscriptionSource {
  final File file;
  const FileSource(this.file);
}

final class ClipboardSource extends SubscriptionSource {
  final String contents;
  const ClipboardSource(this.contents);
}

final class InlineSource extends SubscriptionSource {
  final String body;
  const InlineSource(this.body);
}

final class QrSource extends SubscriptionSource {
  final String content;
  const QrSource(this.content);
}

class FetchResult {
  final String body;
  final SubscriptionMeta? meta;
  final Map<String, String> headers;
  const FetchResult(this.body, [this.meta, this.headers = const {}]);
}

class ParseResult {
  final List<NodeSpec> nodes;
  final SubscriptionMeta? meta;
  final DecodedBody decoded;
  final String rawBody;
  final Map<String, String> headers;
  const ParseResult(this.nodes, this.decoded,
      [this.meta, this.rawBody = '', this.headers = const {}]);
}

/// Fetch + decode + parse — верхнеуровневый pipeline одного источника (§3.1).
///
/// Мержит HTTP-заголовки с inline псевдо-заголовками (`# profile-title: …`
/// в начале тела) — некоторые провайдеры кладут метаданные в комменты,
/// а не в HTTP-headers. HTTP первичны, inline как fallback.
Future<ParseResult> parseFromSource(SubscriptionSource source,
    {http.Client? client}) async {
  final fetch = await _fetch(source, client ?? http.Client());
  final inline = _inlineHeaders(fetch.body);
  // inline под капотом, HTTP поверх — HTTP первичны.
  final merged = <String, String>{...inline, ...fetch.headers};
  final meta = _metaFromHeaders(merged);
  final decoded = decode(fetch.body);
  final nodes = parseAll(decoded);
  return ParseResult(nodes, decoded, meta, fetch.body, fetch.headers);
}

/// Извлекает `# key: value` из первых строк-комментариев тела подписки.
/// Поддерживает `#`, `//`, `;` как префиксы, стопается на первой не-comment
/// не-пустой строке.
Map<String, String> _inlineHeaders(String body) {
  final out = <String, String>{};
  for (final raw in body.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final isComment = line.startsWith('#') ||
        line.startsWith('//') ||
        line.startsWith(';');
    if (!isComment) break; // первая нормальная строка — секция комментов кончилась
    // Сносим префикс-коммент, оставляем содержимое.
    final stripped = line.replaceFirst(RegExp(r'^(#+|//|;)\s*'), '');
    final colon = stripped.indexOf(':');
    if (colon <= 0) continue;
    final key = stripped.substring(0, colon).trim().toLowerCase();
    final value = stripped.substring(colon + 1).trim();
    if (key.isEmpty || value.isEmpty) continue;
    // Только «подписочные» ключи — не захватывать произвольные комменты.
    // content-disposition используется как fallback для имени подписки
    // (см. _metaFromHeaders).
    if (const {
      'profile-title',
      'profile-update-interval',
      'profile-web-page-url',
      'support-url',
      'subscription-userinfo',
      'content-disposition',
    }.contains(key)) {
      out[key] = value;
    }
  }
  return out;
}

/// Прямой HTTP GET без декода/парса. Для UI «Source» — показать живой
/// ответ сервера как есть. Не пишет в кэш.
Future<FetchResult> fetchRaw(SubscriptionSource source,
    {http.Client? client}) async =>
    _fetch(source, client ?? http.Client());

Future<FetchResult> _fetch(SubscriptionSource source, http.Client client) async {
  switch (source) {
    case UrlSource(url: final u, userAgent: final ua, timeout: final t):
      // 2 попытки с паузой 2с. Итого cap ≈ 9+2+9 = 20 сек.
      // Ретрай нужен для transient'ов мобильной сети (DNS fail, RST сразу
      // после TCP-open, DDoS-guard challenge на первый запрос).
      Object? lastErr;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final resp = await client
              .get(Uri.parse(u), headers: {'User-Agent': ua})
              .timeout(t);
          if (resp.statusCode >= 400) {
            throw HttpException('HTTP ${resp.statusCode} for $u');
          }
          return FetchResult(resp.body, _metaFromHeaders(resp.headers),
              Map<String, String>.from(resp.headers));
        } catch (e) {
          lastErr = e;
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(seconds: 2));
          }
        }
      }
      throw lastErr ?? Exception('fetch failed');
    case FileSource(file: final f):
      return FetchResult(await f.readAsString());
    case ClipboardSource(contents: final c):
      return FetchResult(c);
    case InlineSource(body: final b):
      return FetchResult(b);
    case QrSource(content: final c):
      return FetchResult(c);
  }
}

/// Некоторые сервера (Liberty и др.) отдают title как
/// `base64:TGliZXJ0eSBWUE4g...`. Декодируем если есть префикс.
String? _decodeBase64Title(String? raw) {
  if (raw == null) return null;
  const prefix = 'base64:';
  if (!raw.startsWith(prefix)) return raw;
  try {
    final bytes = base64.decode(raw.substring(prefix.length));
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return raw;
  }
}

/// Достаёт имя файла из `Content-Disposition` (RFC 6266). Порядок:
/// `filename*=UTF-8''<percent-encoded>` (RFC 5987, юникод) → `filename="…"`
/// → `filename=…`. Используется как fallback для `profile-title`, когда
/// провайдер не ставит кастомный заголовок, но стандартную админку (Marzban,
/// 3x-ui, XrayR) — ставит. Расширение `.txt/.yaml/.yml/.json/.conf`
/// срезаем — это имя подписки, не файла.
String? _parseContentDispositionFilename(String? header) {
  if (header == null || header.isEmpty) return null;
  String? name;
  // RFC 5987: filename*=UTF-8''<percent-encoded> — приоритетнее.
  final ext = RegExp(
    r"filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)",
    caseSensitive: false,
  ).firstMatch(header);
  if (ext != null) {
    try {
      final decoded = Uri.decodeComponent(ext.group(1)!.trim());
      if (decoded.isNotEmpty) name = decoded;
    } catch (_) {/* fallthrough */}
  }
  if (name == null) {
    final m = RegExp(
      r'filename\s*=\s*("([^"]*)"|([^;]+))',
      caseSensitive: false,
    ).firstMatch(header);
    if (m != null) {
      final raw = (m.group(2) ?? m.group(3) ?? '').trim();
      if (raw.isNotEmpty) name = raw;
    }
  }
  if (name == null) return null;
  var out = name;
  // Срезаем расширения типичных подписочных файлов.
  for (final e in const ['.txt', '.yaml', '.yml', '.json', '.conf']) {
    if (out.toLowerCase().endsWith(e)) {
      out = out.substring(0, out.length - e.length);
      break;
    }
  }
  out = out.trim();
  return out.isEmpty ? null : out;
}

SubscriptionMeta? _metaFromHeaders(Map<String, String> h) {
  // Case-insensitive lookup.
  String? get(String key) {
    for (final k in h.keys) {
      if (k.toLowerCase() == key.toLowerCase()) return h[k];
    }
    return null;
  }

  final userInfo = get('subscription-userinfo');
  // Fallback-цепочка для имени: profile-title → content-disposition.
  // profile-title первичен — провайдер явно обозначил имя подписки.
  // content-disposition — стандартный HTTP header, который многие админки
  // (Marzban/3x-ui/XrayR) ставят автоматически, но без кастомного
  // profile-title.
  final title = _decodeBase64Title(get('profile-title')) ??
      _parseContentDispositionFilename(get('content-disposition'));
  final webPage = get('profile-web-page-url');
  final support = get('support-url');
  final updateIntervalRaw = get('profile-update-interval');

  if (userInfo == null &&
      title == null &&
      webPage == null &&
      support == null &&
      updateIntervalRaw == null) {
    return null;
  }

  int upload = 0, download = 0, total = 0;
  int? expire;
  if (userInfo != null) {
    for (final p in userInfo.split(';')) {
      final kv = p.trim().split('=');
      if (kv.length != 2) continue;
      final n = int.tryParse(kv[1].trim()) ?? 0;
      switch (kv[0].trim()) {
        case 'upload':
          upload = n;
        case 'download':
          download = n;
        case 'total':
          total = n;
        case 'expire':
          expire = n;
      }
    }
  }
  final updateHours = int.tryParse((updateIntervalRaw ?? '').trim());

  return SubscriptionMeta(
    uploadBytes: upload,
    downloadBytes: download,
    totalBytes: total,
    expireTimestamp: expire,
    supportUrl: support,
    webPageUrl: webPage,
    profileTitle: title,
    updateIntervalHours: updateHours,
  );
}
