/// §053 Stage 1 — pure normalizers для CustomRuleEditScreen полей.
///
/// Extract'нуто из `custom_rule_edit_screen.dart`. Принимают raw user input
/// (multiline + comma-separated), возвращают clean `List<String>`
/// готовый к сохранению в model.
///
/// Конвенция: пустые / whitespace-only записи отбрасываются. Регистр —
/// каждая функция документирует своё поведение.
library;

import '../../models/custom_rule.dart'
    show
        kRuleKeyDomain,
        kRuleKeyDomainKeyword,
        kRuleKeyDomainRegex,
        kRuleKeyDomainSuffix,
        kRuleKeyPackageNameRegex,
        kRuleKeyWifiBssid;
import 'punycode.dart';

/// Split по `\n` и `,` — оба разделителя поддерживаются, чтобы юзер мог
/// вставлять из clipboard любой формы. Trim'ит и отбрасывает empty.
List<String> splitRaw(String text) => text
    .split(RegExp(r'[\n,]'))
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

/// §712 — split только по `\n`: в регулярке запятая значимая (`{1,3}`).
/// Trim, пустые строки отбрасываются.
List<String> splitLines(String text) => text
    .split('\n')
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

/// §712 — `package_name_regex` / `domain_regex`: по строке на регулярку,
/// регистр не трогаем (в RE2 он значим).
List<String> normalizedRegexes(String raw) => splitLines(raw);

/// Normalized domains:
/// - lower-case (Unicode-aware: `Ü`→`ü` до punycode)
/// - strip `http://` / `https://` префикса (юзер мог скопировать URL)
/// - strip trailing `/`
/// - опционально strip leading `.` (для `domain_suffix` где `.ru` =
///   `ru` в sing-box terms)
/// - §144 IDNA ToASCII: не-ASCII лейблы → punycode `xn--…` (юзер вводит
///   `.рф` / `почта.рф`, sing-box получает ASCII `xn--p1ai`)
List<String> normalizedDomains(
  String raw, {
  bool stripLeadingDot = false,
}) =>
    splitRaw(raw).map((s) {
      var v = s.toLowerCase();
      if (v.startsWith('http://')) v = v.substring(7);
      if (v.startsWith('https://')) v = v.substring(8);
      if (v.endsWith('/')) v = v.substring(0, v.length - 1);
      if (stripLeadingDot && v.startsWith('.')) v = v.substring(1);
      return domainToAscii(v);
    }).where((s) => s.isNotEmpty).toList();

/// Domain keywords — просто lower-case (substring match в sing-box
/// case-sensitive, но юзеры обычно ожидают case-insensitive).
List<String> normalizedKeywords(String raw) =>
    splitRaw(raw).map((s) => s.toLowerCase()).toList();

/// CIDRs — авто-добавляет /32 (IPv4) или /128 (IPv6) если юзер указал
/// голый IP без mask. Sing-box требует mask explicit.
List<String> normalizedCidrs(String raw) => splitRaw(raw).map((s) {
      if (!s.contains('/')) return s.contains(':') ? '$s/128' : '$s/32';
      return s;
    }).toList();

/// Ports / port ranges — pass-through split (validation отдельно через
/// validators.isValidPort / isValidPortRange).
List<String> normalizedPorts(String raw) => splitRaw(raw);
List<String> normalizedPortRanges(String raw) => splitRaw(raw);

// ─── §757: значение поля условия ─────────────────────────────────────

/// §757 — приведение текста поля условия (вид `lines` / `processes` таблицы
/// условий) к значению ключа: у доменных ключей — те же нормализаторы, что
/// у прежних полей формы (punycode, срез схемы, ведущей точки суффикса),
/// регулярки — по строке без смены регистра, BSSID — в нижнем регистре.
/// Остальные — по строке, пустые отбрасываются. Это приведение значения
/// ключа, не выбор условий: какие условия и поля показывать, решает таблица.
List<String> normalizedConditionLines(String key, String text) =>
    switch (key) {
      kRuleKeyDomain => normalizedDomains(text),
      kRuleKeyDomainSuffix => normalizedDomains(text, stripLeadingDot: true),
      kRuleKeyDomainKeyword => normalizedKeywords(text),
      kRuleKeyWifiBssid => [for (final l in splitLines(text)) l.toLowerCase()],
      _ => splitLines(text),
    };

/// §757 — значение ключа — регулярки (ядро на битой не стартует).
bool isRegexConditionKey(String key) =>
    key == kRuleKeyDomainRegex || key == kRuleKeyPackageNameRegex;
