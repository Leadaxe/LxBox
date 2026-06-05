/// §048 — Pure filter logic для node list на главной screen'е.
///
/// **Двухфазная модель** (см. spec §048):
/// 1. **Pool filter** (detour show/hide) — делает caller, убирает ноды из
///    render вообще.
/// 2. **Match filter** — этот класс. Помечает оставшиеся ноды `matches: bool`
///    для visual hint (NodeRow → opacity 0.4 если false).
///
/// `NodeFilter` **не знает про detour** — это семантически другая концепция
/// (pool filter в caller, не часть predicate).
///
/// Spec: docs/spec/features/048 home-node-filters/spec.md
class NodeFilter {
  const NodeFilter({
    required this.regex,
    this.regexInvert = false,
    required this.protocols,
    required this.subscriptions,
    required this.maxPingMs,
    required this.protocolOf,
    required this.subscriptionOf,
    required this.pingOf,
  });

  /// Compiled regex. `null` если pattern пустой / invalid / checkbox off
  /// (filter no-op).
  final RegExp? regex;

  /// `true` → invert match (regex работает как NOT): tag passes только если
  /// **не** matchает pattern. UI toggle — `!` icon в suffix.
  final bool regexInvert;

  /// Allowed protocol names (`vless`, `vmess`, ...). `empty = no filter`.
  final Set<String> protocols;

  /// Allowed subscription identifiers. `entry.id` для подписок, `'custom'`
  /// для UserServer'ов. `empty = no filter`.
  final Set<String> subscriptions;

  /// Maximum delay в ms. `null = no filter`. Untested nodes (`pingOf(tag) == null`)
  /// **всегда** проходят filter (locked decision #11).
  final int? maxPingMs;

  /// Lookup protocol по tag. `null` = unknown (cache miss или urltest без
  /// selected member). При active protocol filter → non-matching
  /// (locked decision #12).
  final String? Function(String) protocolOf;

  /// Lookup subscription id по tag. `null` = UserServer / untracked
  /// (попадает в категорию `'custom'`).
  final String? Function(String) subscriptionOf;

  /// Lookup ping ms по tag. `null` = untested (нет в `state.lastDelay`).
  final int? Function(String) pingOf;

  /// Pure predicate: проходит ли tag все active match-фильтры.
  /// Detour exclusion здесь **не проверяется** — это pool filter в caller.
  ///
  /// Возвращает `bool matches` → caller передаёт в `NodeViewItem.matches`.
  bool passes(String tag) {
    if (regex != null) {
      // !invert: keep matches → fail if !hasMatch  →  m == false == invert
      //  invert: keep non-matches → fail if hasMatch  →  m == true == invert
      // Обе ветки сводятся к `m == regexInvert → fail`.
      final m = regex!.hasMatch(tag);
      if (m == regexInvert) return false;
    }
    if (protocols.isNotEmpty) {
      final p = protocolOf(tag);
      // Unknown protocol при active filter → non-matching.
      if (p == null || !protocols.contains(p)) return false;
    }
    if (subscriptions.isNotEmpty &&
        !subscriptions.contains(subscriptionOf(tag) ?? 'custom')) {
      return false;
    }
    final delay = pingOf(tag);
    // Untested (delay == null) ВСЕГДА проходят ping filter.
    if (maxPingMs != null && delay != null && delay > maxPingMs!) {
      return false;
    }
    return true;
  }

  /// Regex для emoji extraction. Сочетание Extended_Pictographic (☀, ⚡, 👑,
  /// flag-of-bw-emoji, etc) + Regional_Indicator pair (RIS+RIS = country
  /// flags типа 🇷🇺, которые в Unicode представлены парой code points).
  static final _emojiRe = RegExp(
    r'(\p{Regional_Indicator}\p{Regional_Indicator}|\p{Extended_Pictographic})',
    unicode: true,
  );

  /// Извлечь unique emoji из всех tags. Возвращает в порядке убывания
  /// частоты, ties resolve'ятся alphabetically.
  ///
  /// Для UI: emoji chip row — юзер тапает chip → emoji вставляется в regex
  /// field как character class (one-tap «🇷🇺» → only RU nodes).
  static List<String> extractEmojis(List<String> tags) {
    final freq = <String, int>{};
    for (final tag in tags) {
      for (final m in _emojiRe.allMatches(tag)) {
        final e = m.group(0)!;
        freq[e] = (freq[e] ?? 0) + 1;
      }
    }
    final list = freq.entries.toList()
      ..sort((a, b) {
        final byFreq = b.value.compareTo(a.value);
        return byFreq != 0 ? byFreq : a.key.compareTo(b.key);
      });
    return list.map((e) => e.key).toList();
  }
}
