import 'dart:convert';
import 'dart:math';

/// Максимальная длина URI (защита от мусорных base64-бомб). Совпадает с v1.
const int maxURILength = 65536;

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
String decodeFragment(String fragment) {
  if (fragment.isEmpty) return '';
  try {
    return sanitizeForDisplay(Uri.decodeComponent(fragment));
  } catch (_) {
    return sanitizeForDisplay(fragment);
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

/// Reality short-id canonical form: hex-чар (0-9a-f), max 16.
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
  return out.length > 16 ? out.substring(0, 16) : out;
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
