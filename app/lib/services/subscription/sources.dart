import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/import_rule.dart';
import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../../models/subscription_meta.dart';
import '../parser/body_decoder.dart';
import '../parser/parse_all.dart';
import 'import_rules.dart';
import 'subscription_identity.dart';
import 'user_agent.dart';

/// Источник подписки/узлов (§3.1 спеки 026). Sealed — топ-функция `fetch`
/// делает exhaustive switch.
sealed class SubscriptionSource {
  const SubscriptionSource();
}

final class UrlSource extends SubscriptionSource {
  final String url;

  /// Кастомный UA. `null` (дефолт) → `_fetch` резолвит брендированный
  /// `LxBox-android/<ver>` (см. [user_agent.dart]).
  ///
  /// Некоторые провайдеры выбирают формат тела по UA: неопознанному клиенту
  /// отдают JSON-конфиг/заглушку, опознанному — base64 URI-list (который ест
  /// парсер v2). Бренд-токен `LxBox-android` опознаётся панелями
  /// (Remnawave/Marzban); голого `singbox` в UA нет.
  final String? userAgent;

  /// §289 — per-subscription слепок идентичности. `null` → фетч использует
  /// глобальный `SubscriptionIdentity` (режим Default). Не-null → ТОЛЬКО эти
  /// значения (режим Custom), глобальные игнорируются.
  final SubscriptionIdentityOverride? identity;

  final Duration timeout;
  const UrlSource(
    this.url, {
    this.userAgent,
    this.identity,
    // Короткий таймаут на попытку. Fetch делает 3 попытки с exp backoff
    // (1s, 3s): 9+1+9+3+9 ≈ 31s worst case (см. `_fetch`).
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

  /// §302 — строки (послезаменные), помеченные DISABLE-правилом. Этап B в
  /// контроллере парсит их (`parseUri`) и выключает ноды через §283.
  final Set<String> disabledLines;

  /// §302 — карта `послезаменная строка → оригинал` для строк, изменённых
  /// REPLACE. Контроллер кладёт оригинал в `NodeSpec.originLine` (для UI).
  final Map<String, String> originByRewritten;

  const ParseResult(this.nodes, this.decoded,
      [this.meta,
      this.rawBody = '',
      this.headers = const {},
      this.disabledLines = const {},
      this.originByRewritten = const {}]);
}

/// Fetch + decode + parse — верхнеуровневый pipeline одного источника (§3.1).
///
/// Мержит HTTP-заголовки с inline псевдо-заголовками (`# profile-title: …`
/// в начале тела) — некоторые провайдеры кладут метаданные в комменты,
/// а не в HTTP-headers. HTTP первичны, inline как fallback.
Future<ParseResult> parseFromSource(SubscriptionSource source,
    {http.Client? client, List<ImportRule> importRules = const []}) async {
  // §219 — закрываем ТОЛЬКО самосозданный клиент (инжектированный извне
  // закрывает владелец): иначе `http.Client()` течёт на каждый fetch.
  final owned = client == null;
  final c = client ?? http.Client();
  try {
    final fetch = await _fetch(source, c);
    final inline = _inlineHeaders(fetch.body);
    // inline под капотом, HTTP поверх — HTTP первичны.
    final merged = <String, String>{...inline, ...fetch.headers};
    final meta = _metaFromHeaders(merged);
    final decoded = decode(fetch.body);
    // §302 — этап A: import-rules (REPLACE + пометка DISABLE-строк) на
    // ДЕКОДИРОВАННОМ теле, ДО парсинга. Пустой список → no-op (тот же decoded).
    final ruled = applyImportRules(decoded, importRules);
    final nodes = parseAll(ruled.body);
    return ParseResult(nodes, ruled.body, meta, fetch.body, fetch.headers,
        ruled.disabledLines, ruled.originByRewritten);
  } finally {
    if (owned) c.close();
  }
}

// §219 — паттерны на module-level: раньше `_commentPrefixRe` компилился на
// КАЖДОЙ итерации цикла разбора комментариев, `_newlineRe` — на каждый вызов.
final _newlineRe = RegExp(r'\r?\n');
final _commentPrefixRe = RegExp(r'^(#+|//|;)\s*');

/// Извлекает `# key: value` из первых строк-комментариев тела подписки.
/// Поддерживает `#`, `//`, `;` как префиксы, стопается на первой не-comment
/// не-пустой строке.
Map<String, String> _inlineHeaders(String body) {
  final out = <String, String>{};
  for (final raw in body.split(_newlineRe)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final isComment = line.startsWith('#') ||
        line.startsWith('//') ||
        line.startsWith(';');
    if (!isComment) break; // первая нормальная строка — секция комментов кончилась
    // Сносим префикс-коммент, оставляем содержимое.
    final stripped = line.replaceFirst(_commentPrefixRe, '');
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

/// Backoff'ы между ретраями `_fetch`. Прод-значения; тесты подменяют на
/// нулевые (`fetchBackoffsForTesting`), иначе каждый ретрай-кейс спал бы
/// 1s+3s и в параллельном suite (§101) сдвигался к таймауту → flaky.
const _prodFetchBackoffs = [Duration(seconds: 1), Duration(seconds: 3)];
List<Duration>? _fetchBackoffsOverride;

/// Только для тестов: подменить backoff'ы ретраев. `null` возвращает
/// прод-поведение. Вызывать в `setUp`/`tearDown`.
set fetchBackoffsForTesting(List<Duration>? value) =>
    _fetchBackoffsOverride = value;

/// Прямой HTTP GET без декода/парса. Для UI «Source» — показать живой
/// ответ сервера как есть. Не пишет в кэш.
Future<FetchResult> fetchRaw(SubscriptionSource source,
    {http.Client? client}) async {
  // §219 — закрываем только самосозданный клиент (см. parseFromSource).
  final owned = client == null;
  final c = client ?? http.Client();
  try {
    return await _fetch(source, c);
  } finally {
    if (owned) c.close();
  }
}

Future<FetchResult> _fetch(SubscriptionSource source, http.Client client) async {
  switch (source) {
    case UrlSource(
        url: final u,
        userAgent: final ua,
        identity: final id,
        timeout: final t
      ):
      // §289 — режим Default (id == null): UA = per-source > глобальный override
      // > брендированный; HWID-заголовки из глобального SubscriptionIdentity.
      // Режим Custom (id != null): UA и HWID-заголовки ТОЛЬКО из слепка;
      // глобальные игнорируются. Пустой UA в слепке → брендированный дефолт.
      final String effectiveUa;
      final Map<String, String> idHeaders;
      if (id != null) {
        effectiveUa = id.userAgent.isNotEmpty
            ? id.userAgent
            : resolveSubscriptionUserAgent();
        idHeaders = SubscriptionIdentity.headersFrom(
          sendHwid: id.sendHwid,
          hwid: id.hwid,
          deviceOs: id.deviceOs,
          verOs: id.verOs,
          deviceModel: id.deviceModel,
        );
      } else {
        final override = SubscriptionIdentity.userAgentOverride;
        effectiveUa = ua ??
            (override.isNotEmpty ? override : resolveSubscriptionUserAgent());
        idHeaders = SubscriptionIdentity.fetchHeaders();
      }
      final reqHeaders = <String, String>{
        'User-Agent': effectiveUa,
        ...idHeaders,
      };
      // 3 попытки с exp backoff (1s, 3s) — worst case ~31s (9+1+9+3+9).
      // Retry нужен для transient'ов мобильной сети (DNS fail, RST сразу
      // после TCP-open, DDoS-guard challenge, 5xx). 4xx — permanent,
      // не ретраим (auth fail, removed subscription).
      Object? lastErr;
      final backoffs = _fetchBackoffsOverride ?? _prodFetchBackoffs;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final resp = await client
              .get(Uri.parse(u), headers: reqHeaders)
              .timeout(t);
          if (resp.statusCode >= 400 && resp.statusCode < 500) {
            throw HttpException('HTTP ${resp.statusCode} for $u');
          }
          if (resp.statusCode >= 500) {
            throw HttpException('HTTP ${resp.statusCode} for $u');
          }
          return FetchResult(resp.body, _metaFromHeaders(resp.headers),
              Map<String, String>.from(resp.headers));
        } on HttpException catch (e) {
          lastErr = e;
          // 4xx permanent — не ретраим.
          if (e.message.contains(RegExp(r'HTTP 4\d\d'))) rethrow;
          if (attempt < backoffs.length) {
            await Future<void>.delayed(backoffs[attempt]);
          }
        } catch (e) {
          lastErr = e;
          if (attempt < backoffs.length) {
            await Future<void>.delayed(backoffs[attempt]);
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
  // Срезаем расширения типичных подписочных файлов. §219 — lowercase один раз
  // до цикла (было .toLowerCase() на каждой из 5 итераций).
  final outLower = out.toLowerCase();
  for (final e in const ['.txt', '.yaml', '.yml', '.json', '.conf']) {
    if (outLower.endsWith(e)) {
      out = out.substring(0, out.length - e.length);
      break;
    }
  }
  out = out.trim();
  return out.isEmpty ? null : out;
}

SubscriptionMeta? _metaFromHeaders(Map<String, String> h) {
  // §219 — строим lower-map ОДИН раз: раньше get() линейно сканировал h.keys
  // с .toLowerCase() на каждом, и звался 6 раз → O(n×6). Ключи выше по стеку
  // уже уникальны; при коллизии регистра берём первое вхождение.
  final hLower = <String, String>{};
  for (final e in h.entries) {
    hLower.putIfAbsent(e.key.toLowerCase(), () => e.value);
  }
  String? get(String key) => hLower[key.toLowerCase()];

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
      final parsed = int.tryParse(kv[1].trim());
      // upload/download/total: дефолт 0 (нет трафика). expire: §219 — null при
      // непарсимом значении, НЕ 0 (0 = реальный timestamp эпохи 1970-01-01,
      // а не «нет срока»).
      final n = parsed ?? 0;
      switch (kv[0].trim()) {
        case 'upload':
          upload = n;
        case 'download':
          download = n;
        case 'total':
          total = n;
        case 'expire':
          expire = parsed;
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
