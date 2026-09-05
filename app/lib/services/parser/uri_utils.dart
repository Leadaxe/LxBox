import 'dart:convert';
import 'dart:math';

import '../../models/node_spec.dart' show Awg;
import '../../models/node_warning.dart';
import '../app_log.dart';

/// Максимальная длина URI (защита от мусорных base64-бомб). Совпадает с v1.
const int maxURILength = 65536;

/// §368 §4 P2 / §404 — предел длины цепочки релеев. Реальные конфиги — 2–3
/// звена; лимит защищает от рекурсии по данным провайдера. Общий для
/// sing-box-`detour` и Xray-`sockopt.dialerProxy`: это одна и та же цепочка,
/// записанная в двух схемах. Живёт здесь, а не в `singbox_config.dart`,
/// потому что оба разборщика уже импортируют `uri_utils` — иначе вышел бы
/// круговой импорт.
const int kMaxDetourDepth = 8;

/// Отдельный потолок сырой `vpn://`-ссылки (contract/registry/limits.json →
/// amnezia_link_max_bytes).
///
/// Amnezia-профиль везёт целый конфиг, а с сертификатами штатно перерастает
/// общий [maxURILength]: под общим лимитом такая ссылка молча терялась, хотя
/// десктоп её принимал (§103 §9.B12).
const int maxAmneziaLinkLength = 524288;

/// §084 M7 — charset валидного имени HTTP-заголовка из DuckSoft de-facto
/// спеки naive URI: `! # $ % & ' * + - . 0-9 A-Z \ ^ _ ` a-z | ~`.
/// Единый источник для parser (uri_parsers) и emit (node_spec_emit).
final RegExp naiveHeaderNameRe =
    RegExp(r"^[!#$%&'*+\-.0-9A-Z\\^_`a-z|~]+$");

/// True если `name` — валидное имя naive HTTP-заголовка (непустое +
/// matches [naiveHeaderNameRe]).
bool isValidNaiveHeaderName(String name) =>
    name.isNotEmpty && naiveHeaderNameRe.hasMatch(name);

/// Безопасный base64-decode с пробой 4 вариантов (standard/url-safe ×
/// padded/unpadded). Возвращает bytes или null. Порт v1 `_decodeBase64`.
List<int>? decodeBase64Safe(String s) {
  final input = s.replaceAll(RegExp(r'\s+'), '');
  for (final codec in [base64Url, base64]) {
    for (final pad in [true, false]) {
      try {
        var attempt = input;
        if (pad) {
          final rem = attempt.length % 4;
          if (rem == 2) attempt += '==';
          if (rem == 3) attempt += '=';
        }
        return codec.decode(attempt);
      } catch (_) {}
    }
  }
  return null;
}

/// Base64 alphabet lookup (std, index-compatible with url-safe: `+`/`-` and
/// `/`/`_` map to the same 6-bit value at position 62/63).
final Map<int, int> _b64CharValue = {
  for (var i = 0; i < 26; i++) 'A'.codeUnitAt(0) + i: i,
  for (var i = 0; i < 26; i++) 'a'.codeUnitAt(0) + i: 26 + i,
  for (var i = 0; i < 10; i++) '0'.codeUnitAt(0) + i: 52 + i,
  '+'.codeUnitAt(0): 62,
  '-'.codeUnitAt(0): 62,
  '/'.codeUnitAt(0): 63,
  '_'.codeUnitAt(0): 63,
};

/// Lenient base64 decode matching Go's `encoding/base64` StdEncoding/
/// URLEncoding: unlike `dart:convert`'s `base64`/`base64Url` codecs, Go does
/// NOT reject a final group whose unused low padding bits are non-zero
/// (canonical form has them zero, but Go still decodes the non-canonical
/// form — D-030's whole premise: `…ccC=` and `…ccA=` both decode to the
/// same 32 bytes). Dart's strict codec throws `FormatException: Invalid
/// encoding before padding` on exactly this input, so a manual decode is
/// needed to match core behavior instead of over-rejecting valid keys.
/// Accepts std/url-safe chars mixed, with or without `=` padding. Returns
/// null on any invalid character or on a length that isn't decodable.
List<int>? _decodeBase64Lenient(String s) {
  final trimmed = s.replaceAll(RegExp(r'=+$'), '');
  if (trimmed.isEmpty) return null;
  final values = <int>[];
  for (final unit in trimmed.codeUnits) {
    final v = _b64CharValue[unit];
    if (v == null) return null;
    values.add(v);
  }
  // 2 leftover chars encode 1 byte, 3 leftover chars encode 2 bytes; 1
  // leftover char is invalid base64 (needs at least 2).
  final rem = values.length % 4;
  if (rem == 1) return null;

  final out = <int>[];
  var i = 0;
  while (i + 4 <= values.length) {
    final n = (values[i] << 18) |
        (values[i + 1] << 12) |
        (values[i + 2] << 6) |
        values[i + 3];
    out.add((n >> 16) & 0xFF);
    out.add((n >> 8) & 0xFF);
    out.add(n & 0xFF);
    i += 4;
  }
  if (rem == 2) {
    final n = (values[i] << 18) | (values[i + 1] << 12);
    out.add((n >> 16) & 0xFF);
  } else if (rem == 3) {
    final n = (values[i] << 18) | (values[i + 1] << 12) | (values[i + 2] << 6);
    out.add((n >> 16) & 0xFF);
    out.add((n >> 8) & 0xFF);
  }
  return out;
}

/// SPEC 103 D-023/D-030 — валидирует и канонизирует WireGuard-ключ
/// (private/public/preshared) из share-URI или .conf. Эталон Go
/// `normalizeWGKey` (core/config/subscription/node_parser_wireguard.go):
/// декодирует любой из 4 вариантов base64 (std/url-safe × padded/unpadded),
/// лениво (как Go `encoding/base64`, не строгий `dart:convert` — D-030
/// специально требует принимать неканоническую форму `…ccC=`), требует
/// РОВНО 32 байта (мусор вроде Proton'овского "*****" или урезанного
/// `publickey=enabled` иначе не отсеять — D-023), возвращает канонический
/// std-base64 (D-030: `…ccC=`/`…ccA=` декодируют в одни и те же 32 байта,
/// но уезжают в конфиг по-разному → разные identity-хеши).
/// `null` → нода отбрасывается вызывающим (parse_error, CANON §4).
String? normalizeWGKey(String value) {
  final raw = _decodeBase64Lenient(value);
  if (raw == null || raw.length != 32) return null;
  return base64.encode(raw);
}

/// §025 — WireGuard `reserved` (Cloudflare WARP client_id), ровно 3 байта.
/// Принимает два формата:
///   • `b0,b1,b2` — три десятичных числа 0..255 (наш round-trip формат);
///   • base64 (WARP `client_id`, 3 байта) — через [decodeBase64Safe].
/// Возвращает `[b0,b1,b2]` или null (битый / не 3 байта / вне 0..255).
List<int>? parseReserved(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  if (s.contains(',')) {
    final parts = s.split(',').map((e) => e.trim()).toList();
    if (parts.length != 3) return null;
    final out = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return null;
      out.add(n);
    }
    return out;
  }
  final bytes = decodeBase64Safe(s);
  if (bytes == null || bytes.length != 3) return null;
  if (bytes.any((b) => b < 0 || b > 255)) return null;
  return List<int>.from(bytes);
}

/// UTF-8 декод с fallback'ом на allowMalformed.
String utf8Lossy(List<int> bytes) =>
    utf8.decode(bytes, allowMalformed: true);

/// Удаление управляющих символов из display-строк (оставляем \t \n \r).
String sanitizeForDisplay(String s) {
  if (s.isEmpty) return s;
  final buf = StringBuffer();
  for (final r in s.runes) {
    if (r == 9 || r == 10 || r == 13) {
      buf.writeCharCode(r);
      continue;
    }
    if (r <= 0x1F || r == 0x7F) continue;
    buf.writeCharCode(r);
  }
  return buf.toString();
}

/// Tag из fragment'а или fallback'а `<scheme>-<server>-<port>`.
/// Нормализация: `🇪🇳` → `🇬🇧` (оставшийся артефакт из v1).
String tagFromLabel(String label, String scheme, String server, int port) {
  if (label.trim().isNotEmpty) {
    return label.trim().replaceAll('🇪🇳', '🇬🇧');
  }
  return '$scheme-$server-$port';
}

/// Разбор `#fragment` → label.
///
/// §103 base64_payload_crlf — base64-обёрнутые hysteria2-ссылки иногда несут
/// хвостовой CRLF (копипаста из чата) прямо после текста фрагмента; Go
/// тримит его в конце label-конвейера (textnorm.NormalizeProxyDisplay →
/// strings.TrimSpace), после sanitize (который намеренно сохраняет \t/\n/\r
/// в середине строки). Зеркалим: sanitize, затем trim только по краям.
String decodeFragment(String fragment) {
  if (fragment.isEmpty) return '';
  try {
    return sanitizeForDisplay(Uri.decodeComponent(fragment)).trim();
  } catch (_) {
    return sanitizeForDisplay(fragment).trim();
  }
}

/// Генерация UUID v4 (для `NodeSpec.id`). Используется при парсинге — id не
/// приходит из URI, а присваивается в момент создания spec'а. Round-trip
/// тесты сравнивают без `id`.
final _rng = Random.secure();
String newUuidV4() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${h(0)}${h(1)}${h(2)}${h(3)}-'
      '${h(4)}${h(5)}-'
      '${h(6)}${h(7)}-'
      '${h(8)}${h(9)}-'
      '${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
}

/// Нормализация insecure-флага: `insecure`, `allowInsecure`, `allowinsecure`,
/// `skip-cert-verify` → bool. Значения `1`, `true`, `yes`.
bool isTlsInsecure(Map<String, String> q) {
  for (final key in [
    'insecure',
    'allowInsecure',
    'allowinsecure',
    'allow_insecure',
    'skip-cert-verify',
  ]) {
    final v = (q[key] ?? '').toLowerCase().trim();
    if (v == '1' || v == 'true' || v == 'yes') return true;
  }
  return false;
}

/// Allow-list нормализации VLESS/VMess `packetEncoding` к sing-box словарю.
///
/// Sing-box `vless.NewOutbound` (и VMess аналог) принимает ровно три формы
/// (https://sing-box.sagernet.org/configuration/outbound/vless/):
///   - `""` (omitted) — disabled, default
///   - `"xudp"` — XUDP wrapper
///   - `"packetaddr"` — packet-addr (v2ray 5+)
///
/// Любое другое значение → `E.New("unknown packet encoding: ", ...)` →
/// panic в `format.ToString` (нативный краш `libbox.so` целиком, не
/// «не подключилось»). Xray-style подписки кладут `packetEncoding=none`,
/// имея в виду «без encoding» — для sing-box это семантический эквивалент
/// omitted, дропаем молча. Регистр нормализуем (xudp/XUDP/Xudp валидны
/// в URI; sing-box принимает только lowercase).
///
/// `tag` — опционально для warning'ов (диагностика проблемной подписки).
/// [warnings] — узловой список: мусорное значение получает
/// `packet_encoding_unknown` (contract/registry/warnings.json). Пустое и
/// `none` — «поля нет», не деградация: кода не дают (Go так же).
String normalizePacketEncoding(
  String raw, {
  String? tag,
  List<NodeWarning>? warnings,
}) {
  final v = raw.trim().toLowerCase();
  if (v.isEmpty || v == 'none') return '';
  if (v == 'xudp' || v == 'packetaddr') return v;
  AppLog.I.warning(
    "unknown packetEncoding='$raw'${tag != null ? ' in $tag' : ''} — dropping",
  );
  warnings?.add(PacketEncodingUnknownWarning(raw.trim()));
  return '';
}

/// §097 — клиентский MTU для AWG-endpoint'а: `min(mtu, 1280)`.
///
/// 1280 = рекомендованный клиентский MTU самой AmneziaWG и минимальный
/// IPv6 MTU → безопасно на любом пути (PPPoE 1492, mobile, вложенные
/// туннели). Точный потолок `1500−60−max(s3,s4)` хрупок: предполагает
/// path-MTU ровно 1500, чего у AWG-юзеров обычно нет. Асимметрия рисков:
/// занижение лишь чуть мельчит пакеты, завышение — тихий облом
/// (handshake есть, данных нет). Явно заниженный MTU уважаем; обычный
/// WG не трогаем (вызывать только при наличии AWG-полей).
/// §421 — проверка AWG3 на УЗЕЛ (не на поле): битый ключ защиты заголовка
/// или слишком короткий паддинг роняют весь конфиг на загрузке ядра, поэтому
/// узел выбрасывается (та же политика, что у битого private/public key).
/// Возвращает причину (`Awg3HeaderKeyInvalidWarning` /
/// `Awg3PaddingTooShortWarning`) или `null`, если всё в порядке. Валидный
/// ключ нормализуется В МЕСТЕ (url-safe/без паддинга → std base64 — единственная
/// форма, которую декодирует ядро; иначе одна нода даёт два identity-хеша).
/// Эталон Go `validateAWG3` (awg3.go).
NodeWarning? awg3NodeError(Awg awg) {
  final raw = awg.fields[Awg.headerKey];
  if (raw is! String || raw.trim().isEmpty) return null;
  final bytes = _decodeBase64Lenient(raw.trim());
  if (bytes == null || bytes.length != 32 || bytes.every((b) => b == 0)) {
    return const Awg3HeaderKeyInvalidWarning();
  }
  awg.fields[Awg.headerKey] = base64.encode(bytes);
  final short = awg.paddingTooShortField;
  if (short != null) {
    return Awg3PaddingTooShortWarning(short, Awg.awg3MinPadding);
  }
  return null;
}

/// §421 — `keepalive`/`PersistentKeepalive`: число как раньше, AWG3-диапазон
/// `N-M` — строкой; мусор → `null` (пропуск, как раньше). Эталон Go:
/// `strconv.Atoi` → `parseAWG3Range` (node_parser_wireguard.go).
Object? parseWgKeepalive(String? raw) {
  final v = (raw ?? '').trim();
  if (v.isEmpty) return null;
  final n = int.tryParse(v);
  if (n != null) return n;
  final r = Awg.parseAwg3Range(v);
  return r is String ? r : null;
}

int awgClampMtu(int? raw, String tag) {
  if (raw == null) return 1280;
  if (raw <= 1280) return raw;
  AppLog.I.debug('$tag: clamped AWG mtu $raw→1280');
  return 1280;
}

/// §106 — bare IP без CIDR-префикса (`172.16.0.2`) ломает sing-box на
/// загрузке endpoint'а: `netip.ParsePrefix(...): no '/'`. Дефолтим bare
/// IPv4 → `/32`, bare IPv6 (есть `:`) → `/128`. Пустое и уже-с-`/` не трогаем.
/// Применяется к `address` и `allowed_ips` WG/AWG из всех входов.
String ensureCidr(String addr) {
  final s = addr.trim();
  if (s.isEmpty || s.contains('/')) return s;
  return s.contains(':') ? '$s/128' : '$s/32';
}

/// §106 — `wireguard://KEY@host`: если base64-ключ содержит сырой `/`,
/// `Uri.tryParse` примет его за начало path и потеряет userInfo → ключ
/// пропадёт. Percent-энкодим `/` **только** в userInfo-части (между `://`
/// и первым `@`); уже-`%2F` не трогаем (там нет raw `/`); query не задеваем.
String encodeUserInfoSlashes(String uri) {
  final schemeEnd = uri.indexOf('://');
  if (schemeEnd < 0) return uri;
  final start = schemeEnd + 3;
  final at = uri.indexOf('@', start);
  if (at < 0) return uri;
  final userInfo = uri.substring(start, at);
  if (!userInfo.contains('/')) return uri;
  return uri.substring(0, start) +
      userInfo.replaceAll('/', '%2F') +
      uri.substring(at);
}

/// §421 — query-параметр с сохранением сырого `+`. `Uri.queryParameters`
/// декодирует по правилам `application/x-www-form-urlencoded` и превращает
/// `+` в пробел — для base64-значения (ключ защиты заголовка AWG3, ключи WG)
/// это «not base64» и потеря узла. Эталон Go `queryParamPreservePlus`
/// (node_parser_wireguard.go): берём сырой query, ищем ключ, снимаем только
/// percent-encoding. `null` — параметра нет.
String? queryParamPreservePlus(Uri u, String key) {
  final raw = u.query;
  if (raw.isEmpty) return null;
  for (final part in raw.split('&')) {
    final eq = part.indexOf('=');
    final k = eq < 0 ? part : part.substring(0, eq);
    if (k != key) continue;
    final v = eq < 0 ? '' : part.substring(eq + 1);
    try {
      return Uri.decodeComponent(v);
    } catch (_) {
      return v;
    }
  }
  return null;
}

/// Case-insensitive lookup query-параметра. В подписках `packetEncoding`
/// встречается в разных регистрах (`packetencoding`, `PacketEncoding`),
/// `Uri.queryParameters` case-sensitive. Возвращает первое совпадение
/// или `null`. Точечный helper — общий CI-lookup для всех ключей менять
/// семантику остальных параметров.
String? queryParamCI(Map<String, String> q, String key) {
  final lk = key.toLowerCase();
  for (final e in q.entries) {
    if (e.key.toLowerCase() == lk) return e.value;
  }
  return null;
}

/// §169 — валидный ли REALITY public key (X25519, ровно 32 байта).
///
/// КОРЕНЬ БАГА: битые публичные подписки вешают на `security=tls` ноды мусор
/// `pbk=enabled` / `pbk=true`. Если строить REALITY-блок по «pbk непустой»,
/// мусор уходит в `reality.public_key` → sing-box видит не-X25519 ключ и
/// отвергает ВЕСЬ config.json (а не одну ноду) → VPN не поднимается вообще.
///
/// Правило: X25519 public key = 32 байта. После trim строка должна
/// декодироваться как base64url/base64 (любой из 4 вариантов pad/url) ровно
/// в 32 байта. `enabled`(7)/`true`(4)/`PK`(2)/пустота(0) отсекаются длиной.
/// Невалидный pbk → REALITY не создаём, нода деградирует до plain TLS.
bool isValidRealityPublicKey(String pbk) {
  final s = pbk.trim();
  if (s.isEmpty) return false;
  final bytes = decodeBase64Safe(s);
  return bytes != null && bytes.length == 32;
}

/// Reality short-id canonical form: hex-чар (0-9a-f), чётной длины, max 16.
///
/// §343: ядро декодирует short_id как hex в `[8]byte` — нечётная длина или
/// >16 символов = fatal ВСЕГО конфига на старте (`decode short_id:
/// encoding/hex: odd length hex string`). Xray-core валидирует идентично,
/// т.е. такой sid не работает нигде — мусор по определению. По принципу
/// §169 битое значение отбрасывается целиком (`''`), НЕ подгоняется:
/// обрезка/дополнение дали бы валидную форму с чужим идентификатором
/// (тихая порча — сервер сверяет sid побайтово). Пустой short_id для
/// REALITY легален (клиент шлёт нулевой `[8]byte`).
String normalizeRealityShortId(String s) {
  final buf = StringBuffer();
  for (final r in s.trim().runes) {
    if (r >= 0x30 && r <= 0x39) {
      buf.writeCharCode(r);
    } else if (r >= 0x61 && r <= 0x66) {
      buf.writeCharCode(r);
    } else if (r >= 0x41 && r <= 0x46) {
      buf.writeCharCode(r + 32);
    }
  }
  final out = buf.toString();
  return (out.length > 16 || out.length.isOdd) ? '' : out;
}

/// SPEC 103 `reality_short_id_invalid` — сырое значение `sid` будет
/// деградировано (не-hex вычищен / всё значение снято). Зеркало Go
/// `realityShortIDWouldDegrade` (parse_warnings.go:72): непустое сырое
/// значение, чья нормализация не совпала с `lower(trim(raw))`. Отдельный
/// предикат, а не флаг из [normalizeRealityShortId], потому что код обязан
/// встать ДО нормализации — после неё исходного значения уже нет.
bool realityShortIdWouldDegrade(String raw) {
  if (raw.isEmpty) return false;
  return normalizeRealityShortId(raw) != raw.trim().toLowerCase();
}

/// SPEC 103 D-024 — bare integer (трактуется как секунды) → sing-box
/// duration string (`"30"` → `"30s"`); значение, уже несущее суффикс единицы
/// измерения (`"30s"`, `"5m"`), проходит без изменений. Зеркало Go
/// `normalizeTuicHeartbeat` (node_parser_tuic.go) — общий для TUIC heartbeat
/// и AnyTLS idle_session_*: ядро (`badoption.Duration`) отвергает голое
/// число ошибкой `time: missing unit in duration` и роняет ВЕСЬ конфиг.
/// Пустая строка проходит как есть (caller решает, эмитить ли поле).
String normalizeSingboxDuration(String v) {
  if (v.isEmpty) return v;
  final isAllDigits = RegExp(r'^[0-9]+$').hasMatch(v);
  return isAllDigits ? '${v}s' : v;
}

/// Нормализация VMess security/cipher к sing-box словарю.
String normalizeVmessSecurity(String raw) {
  final s = raw.toLowerCase().trim();
  if (s.isEmpty || s == 'null' || s == 'undefined') return 'auto';
  switch (s) {
    case 'auto':
    case 'none':
    case 'zero':
    case 'aes-128-gcm':
    case 'chacha20-poly1305':
    case 'aes-128-ctr':
      return s;
    case 'chacha20-ietf-poly1305':
      return 'chacha20-poly1305';
    default:
      return 'auto';
  }
}

/// Валидные методы Shadowsocks (sing-box).
const shadowsocksMethods = {
  '2022-blake3-aes-128-gcm',
  '2022-blake3-aes-256-gcm',
  '2022-blake3-chacha20-poly1305',
  'none',
  'aes-128-gcm',
  'aes-192-gcm',
  'aes-256-gcm',
  'chacha20-ietf-poly1305',
  'xchacha20-ietf-poly1305',
};

bool isValidShadowsocksMethod(String method) =>
    shadowsocksMethods.contains(method);

/// VLESS-порты, на которых обычно plain HTTP (без TLS) — как в v1.
const plaintextVlessPorts = {80, 8080, 8880, 2052, 2082, 2086, 2095};

/// URL-encode query-параметра (для `toUri()`). Пробел → `%20`, не `+`.
String encodeParam(String s) => Uri.encodeQueryComponent(s).replaceAll('+', '%20');

/// URL-encode fragment (для `toUri()` #label).
String encodeFragment(String s) =>
    Uri.encodeComponent(s).replaceAll('+', '%20');

/// Собрать query-string из Map (детерминированный порядок ключей).
String buildQuery(Map<String, String> params) {
  if (params.isEmpty) return '';
  final keys = params.keys.toList()..sort();
  return keys
      .map((k) => '${encodeParam(k)}=${encodeParam(params[k]!)}')
      .join('&');
}
