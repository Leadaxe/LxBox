/// §053 Stage 1 — pure validators для CustomRuleEditScreen полей.
///
/// Extract'нуто из `custom_rule_edit_screen.dart` для:
/// 1. Unit-тестируемости — функции без State, легко покрыть.
/// 2. Readability — главный файл редактора усыхает.
/// 3. Reuse — те же validators могут понадобиться в Debug API parsing
///    (rules.dart) или в backup import flow.
///
/// Все функции работают на already-trimmed input (вызывающая сторона
/// делает `splitRaw` + `trim` перед проверкой).
library;

/// Domain `example.com` / `sub.example.co.uk` — RFC-ish с поддержкой
/// 2+-letter TLD. НЕ пропускает IDN punycode чисто (нужно lower-case
/// на стороне normalizer).
final RegExp _domainRegex = RegExp(
  r'^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$',
);

bool isValidDomain(String v) => _domainRegex.hasMatch(v);

/// §144 — Domain suffix `ru` / `example.com` / `co.uk` / `xn--p1ai`.
/// Слабее `isValidDomain`: sing-box `domain_suffix` — суффиксное сравнение
/// хвоста хоста, поэтому голый TLD (`ru`, `com`) валиден, точка и буквенный
/// TLD необязательны. Один+ валидный DNS-лейбл через точку. Регистр —
/// only-lower: normalizer (match_section) делает toLowerCase + strip
/// leading `.` ДО вызова.
final RegExp _domainSuffixRegex = RegExp(
  r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$',
);

bool isValidDomainSuffix(String v) => _domainSuffixRegex.hasMatch(v);

/// Domain keyword — non-empty без whitespace. Sing-box matcher делает
/// substring search, поэтому пробелы внутри ломают match.
bool isValidKeyword(String v) => v.isNotEmpty && !v.contains(RegExp(r'\s'));

/// CIDR — IPv4 (`1.2.3.4/24`) или IPv6 (`::1/128`). Mask диапазоны
/// `0..32` / `0..128`. Octets `0..255` для v4.
bool isValidCidr(String v) {
  final parts = v.split('/');
  if (parts.length != 2) return false;
  final mask = int.tryParse(parts[1]);
  if (mask == null) return false;
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(parts[0])) {
    if (mask < 0 || mask > 32) return false;
    return parts[0].split('.').every((o) {
      final n = int.tryParse(o);
      return n != null && n >= 0 && n <= 255;
    });
  }
  if (RegExp(r'^[0-9a-fA-F:]+$').hasMatch(parts[0]) &&
      parts[0].contains(':')) {
    return mask >= 0 && mask <= 128;
  }
  return false;
}

/// Single port — `0..65535`.
bool isValidPort(String v) {
  final n = int.tryParse(v);
  return n != null && n >= 0 && n <= 65535;
}

/// Port range — `"8000:9000"`, `":3000"` (≤3000), `"4000:"` (≥4000).
/// Empty с обеих сторон отклоняется.
bool isValidPortRange(String v) {
  final m = RegExp(r'^(\d*):(\d*)$').firstMatch(v);
  if (m == null) return false;
  final lo = m.group(1)!;
  final hi = m.group(2)!;
  if (lo.isEmpty && hi.isEmpty) return false;
  int? loN, hiN;
  if (lo.isNotEmpty) {
    loN = int.tryParse(lo);
    if (loN == null || loN < 0 || loN > 65535) return false;
  }
  if (hi.isNotEmpty) {
    hiN = int.tryParse(hi);
    if (hiN == null || hiN < 0 || hiN > 65535) return false;
  }
  if (loN != null && hiN != null && loN > hiN) return false;
  return true;
}

/// `http://...` или `https://...` с непустым host. Для SRS URL field.
bool isValidUrl(String s) {
  final u = Uri.tryParse(s);
  return u != null &&
      (u.scheme == 'http' || u.scheme == 'https') &&
      u.host.isNotEmpty;
}

/// §051 — BSSID `xx:xx:xx:xx:xx:xx` (case-insensitive). Empty допустимо
/// — chip может быть только с SSID, sing-box матчит по SSID одному.
final RegExp _bssidRegex =
    RegExp(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$');

bool isValidBssid(String v) =>
    v.isEmpty || _bssidRegex.hasMatch(v.trim());
