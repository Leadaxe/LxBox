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
    this.protocolsInvert = false,
    required this.subscriptions,
    this.subscriptionsInvert = false,
    required this.maxPingMs,
    required this.protocolOf,
    required this.subscriptionsOf,
    required this.pingOf,
  });

  /// Compiled regex. `null` если pattern пустой / invalid (filter no-op).
  /// §096 — enable-галки больше нет: активность = непустой валидный паттерн.
  final RegExp? regex;

  /// `true` → invert match (regex работает как NOT): tag passes только если
  /// **не** matchает pattern. UI toggle — `!` icon в suffix.
  final bool regexInvert;

  /// Allowed protocol names (`vless`, `vmess`, ...). `empty = no filter`.
  final Set<String> protocols;

  /// §096 — `true` → invert protocol-фильтр (NOT): нода passes если её протокол
  /// **не** входит в [protocols]. Имеет смысл только при непустом [protocols].
  final bool protocolsInvert;

  /// Allowed subscription identifiers. `entry.id` для подписок, `'custom'`
  /// для UserServer'ов. `empty = no filter`.
  final Set<String> subscriptions;

  /// §096 — `true` → invert subscription-фильтр (NOT): нода passes если она
  /// **не** из выбранных подписок. Имеет смысл только при непустом
  /// [subscriptions].
  final bool subscriptionsInvert;

  /// Maximum delay в ms. `null = no filter`. Untested nodes (`pingOf(tag) == null`)
  /// **всегда** проходят filter (locked decision #11).
  final int? maxPingMs;

  /// Lookup protocol по tag. `null` = unknown (cache miss или urltest без
  /// selected member). При active protocol filter → non-matching
  /// (locked decision #12).
  final String? Function(String) protocolOf;

  /// §091 — какие подписки владеют tag'ом, по префиксу
  /// (`tag.startsWith('$prefix ')`). Возвращает **множество**: при общем
  /// префиксе у нескольких подписок нода видна в chip-фильтре каждой.
  /// Пустой Set = тег не начинается ни с одного префикса (UserServer /
  /// подписка без префикса / импорт) → категория `'custom'`.
  final Set<String> Function(String) subscriptionsOf;

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
      // Membership = протокол известен И выбран. Unknown (null) → не member.
      // §096: fail когда `member == invert` (см. regex выше):
      //   • !invert → fail если !member (unknown при active filter →
      //     non-matching, locked decision #12; «не VLESS» под invert → passes);
      //   •  invert → fail если member.
      final member = p != null && protocols.contains(p);
      if (member == protocolsInvert) return false;
    }
    if (subscriptions.isNotEmpty) {
      final candidates = subscriptionsOf(tag);
      // Пустой Set candidates → нода неизвестного происхождения → 'custom'.
      // Member = хоть одна подписка-кандидат выбрана (intersection non-empty).
      // Ambiguity-aware: коллизионная нода видна во всех chip'ах подписок,
      // которые могли её создать. §096: fail когда `member == invert`.
      final effective = candidates.isEmpty ? const {'custom'} : candidates;
      final member = effective.any(subscriptions.contains);
      if (member == subscriptionsInvert) return false;
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
