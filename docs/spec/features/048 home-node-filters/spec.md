# 048 — Home node filters (regex + emoji + protocol + subscription + ping)

| Поле | Значение |
|------|----------|
| Статус | Released в v1.9.0; контракт NodeFilter уточнён в §077 (v1.9.1) |
| Дата | 2026-05-12 |

> **§077 update (2026-06-07)**: NodeFilter subscription contract обновлён:
> `subscriptionOf: String? Function(String)` → `subscriptionsOf: Set<String> Function(String)`.
> Predicate сводится к intersection (`effective.any(subscriptions.contains)`)
> где empty Set candidates → `'custom'` fallback. Lookup helper переехал
> в pure-функцию [`home/subscription_lookup.dart::subscriptionsOfTag`](../../../app/lib/screens/home/subscription_lookup.dart)
> с prefix-aware comparison + collision-suffix detection + disabled-subs
> skip. Раздел «### NodeFilter» ниже описывает **исходный** контракт;
> текущая реализация = код. Полный rationale — [`tasks/077-subscription-filter-with-prefix.md`](../../tasks/077-subscription-filter-with-prefix.md).

> **§078 update (2026-06-08)**: Filter split в home_screen теперь
> короткозамыкает на control outbounds (selectors/urltest/direct/block/dns).
> `_isControlTag(tag, state)` определяет их через `state.proxiesJson.type`
> → они **всегда** matching независимо от фильтров. `hasCustom` тоже
> исключает control → 'Custom' chip отображается только при наличии
> реальных UserServer'ов. Pure NodeFilter не знает про это — special-case
> в caller. См. [`tasks/078-control-outbound-and-display-order-ping.md`](../../tasks/078-control-outbound-and-display-order-ping.md).

| Зависимости | Нет (hard). |
| Связанные | [`tasks/068 — extract NodeViewItem`](../../tasks/068-node-view-item-extract.md) — выполняется **внутри** этого PR при срабатывании одного из trigger'ов. Home screen node list (`home_screen.dart::_buildNodeList`), `NodeRow` widget (`widgets/node_row.dart`), `HomeState.configCache.protoByTag` (proto lookup), `SubscriptionController.entries` (sub lookup), `state.lastDelay` (ping). |
| Триггер | Сейчас на главной только один toggle — `_showDetourNodes` (показывать ли chained outbound). Юзеру нужно искать ноду по emoji-флагу страны (🇷🇺/🇺🇸/🇩🇪), regex pattern'у или protocol (vless/vmess/trojan/...) — приходится скроллить список или вспоминать tag. |

## Цель

Добавить пять комбинируемых фильтров. Detour show/hide остаётся отдельным механизмом — **pool filter** (видна ли нода вообще), а пять новых — **match filter** (visual hint matching/non-matching).

Фильтры (все AND):
1. **Regex** — text field, фильтрует node tags по regex pattern
2. **Emoji autocomplete** — авто-сканит все emoji в node tags (весь pool, включая detour), показывает chip row для быстрого добавления в regex (one-tap «🇷🇺» → `🇷🇺` в pattern)
3. **Protocol multi-select** — chips (vless / vmess / trojan / shadowsocks / hysteria2 / ...) — пустой выбор = все
4. **Subscription multi-select** — chips с display name каждой `SubscriptionEntry` + «Custom» для `UserServer`. Пустой выбор = все
5. **Ping** — `Ping ≤ [N] ms` numeric input. Пустое = filter off. Untested nodes (`state.lastDelay[tag] == null`) **всегда matching** (filter их не отсекает).

**Non-matching behaviour** (по checkbox «Show non-matching (dimmed)»):
- **ON (default)** — `matches == false` ноды видны внизу с opacity 0.4. Юзер видит весь pool, понимает «вот эти подходят под фильтр».
- **OFF** — `matches == false` ноды скрыты (классический filter).

---

## Двухфазная модель: pool filter vs match filter

| Фаза | Что делает | Кто | Эффект |
|---|---|---|---|
| **1. Pool filter** | Решает, попадает ли нода в render вообще | Caller (`home_screen::_buildNodeList`) | Detour off → нода **отсутствует** в list, никогда не рисуется |
| **2. Match filter** | Помечает оставшиеся ноды `matches: bool` | `NodeFilter.passes(tag)` | Non-matching → render с opacity 0.4 (или hidden если checkbox OFF) |

`NodeFilter` **не знает про detour** — это семантически другая концепция. Detour hide убирает из pool; filter работает с тем что осталось.

```dart
// caller
final isVisible = (String t) => _showDetourNodes || !t.startsWith(kDetourTagPrefix);
final pool = state.sortedNodes.where(isVisible).toList();   // Phase 1

final matching = <String>[];
final nonMatching = <String>[];
for (final tag in pool) {
  if (filter.passes(tag)) matching.add(tag);                // Phase 2
  else nonMatching.add(tag);
}
```

---

## Naming convention

В коде везде **`bool matches`** — single canonical name:
- `matches == true` → нода прошла filter
- `matches == false` → не прошла (будет dimmed визуально)

Не использовать `dimmed`, `passed`, `excluded`, `isPassing` в коде. «Dimmed / non-matching» — только в UI label checkbox'а (user-facing).

## Opacity location

**Внутри `NodeRow.build()`** — single source of truth. Widget сам знает как render себя в matching/non-matching состоянии. Magic number `0.4` не утекает в caller.

```dart
// node_row.dart
@override
Widget build(BuildContext context) {
  return Opacity(
    opacity: matches ? 1.0 : 0.4,
    child: _buildContent(context),
  );
}
```

Caller передаёт только `bool matches`:
```dart
// home_screen.dart::_buildNodeList::itemBuilder
NodeRow(
  // ... existing 14 params ...
  matches: filter.passes(tag),
)
```

**Не**: `Opacity(opacity: 0.4, child: NodeRow(...))` в caller — это leaks visual rule наружу.

## Не в скопе

- Сортировка — порядок внутри matching/non-matching остаётся `state.sortedNodes`
- Search history
- Negative filters
- Custom emoji groups
- Persistence фильтров — per-session in-memory (как `_showDetourNodes`)
- Filter sharing/export
- Filter по speed test — это global one-shot benchmark через active outbound, нет per-node mapping (см. Locked decisions #9)

---

## Locked decisions

| # | Вопрос | Решение |
|---|---|---|
| 1 | Где filter UI | Скрыт по умолчанию, expand по тапу на existing `Icons.tune` icon-button в node list header (заменяет текущий PopupMenuButton с одним пунктом «Show detour servers») |
| 2 | Regex или substring | **Всегда regex** (no auto-detect). Invalid pattern → red hint, filter не применяется. |
| 3 | Emoji scan scope | Из **всего pool** (`state.sortedNodes`, включая detour-prefixed) |
| 4 | Apply timing | **Debounce 300ms** на keystroke в regex и ping field. Chip taps — immediate. |
| 5 | Persistence | **Per-session in-memory** (`_HomeScreenState`). После restart / dispose — сбрасывается. |
| 6 | Combine logic | **AND** для match filter: regex ∧ protocol ∧ subscription ∧ ping. Detour show/hide — отдельная фаза (pool filter), не часть predicate. |
| 7 | Empty/partial result UX | **Checkbox «Show non-matching (dimmed)»** в filter panel. **Default ON** → non-matching ноды показываются внизу с opacity 0.4. OFF → non-matching скрыты. |
| 8 | State location | **Local в `_HomeScreenState`** (не отдельный controller) |
| 9 | Ping filter scope | Только `state.lastDelay` (clash API per-node urltest, ms). **Speed test не подходит** — global one-shot benchmark, не per-node + не batch + не persistent. |
| 10 | Ping operator | `≤` (только «не больше N ms»). Other operators (`<`, `>`, `≥`, `=`) — overkill для use-case «дай мне быстрые ноды». |
| 11 | Untested nodes (delay==null) | **Всегда matching** — ping filter их не отсекает. |
| 12 | Unknown protocol (cache miss) | Если protocol filter active и `protocolOf(tag) == null` → **non-matching**. Pure cache miss treat'им как «не подходит под выбранный proto» (consistent с user-selected filter). |
| 13 | Detour vs filter | **Отдельные механизмы** (см. «Двухфазная модель»). Detour exclusion — pool filter в caller, не часть `NodeFilter.passes`. Existing checkbox «Show detour servers» переезжает внутрь filter panel. |

---

## Текущее состояние

```dart
// home_screen.dart::_buildNodeList
final all = state.sortedNodes;
final displayNodes = _showDetourNodes
    ? all
    : all.where((t) => !t.startsWith(kDetourTagPrefix)).toList();

// header
PopupMenuButton<String>(
  icon: Icon(Icons.tune),
  itemBuilder: (_) => [
    CheckedPopupMenuItem(value: 'detour', checked: _showDetourNodes,
        child: Text('Show detour servers')),
  ],
)
```

Один toggle (icon `Icons.tune` в header, popup с одним пунктом). Detour off → nodes удалены из list. Никаких других фильтров.

---

## Новая модель

### State в `_HomeScreenState`

```dart
String _regexFilter = '';              // raw text input
RegExp? _regexCompiled;                // recompiled с debounce; null если invalid/empty
bool _regexValid = true;                // false → красный hint в field
Set<String> _enabledProtocols = {};    // empty = all protocols allowed
Set<String> _enabledSubscriptions = {};// empty = all subscriptions allowed; ключ = entry.id или 'custom'
int? _maxPingMs;                       // null = no ping filter
bool _filterPanelExpanded = false;     // showing regex + emoji + protocol + subscription + ping + detour + showNonMatching rows
bool _showNonMatching = true;          // ON (default): show non-matching at bottom dimmed; OFF: hide
// _showDetourNodes уже существует (был toggle в popup), default true.
Timer? _regexDebounceTimer;
Timer? _pingDebounceTimer;
```

### Pure helper (new file `lib/screens/home/node_filter.dart`)

```dart
/// NodeFilter — pure predicate с lookup'ами как closure-параметрами.
/// НЕ знает про detour (это pool filter в caller, не часть predicate).
class NodeFilter {
  const NodeFilter({
    required this.regex,
    required this.protocols,
    required this.subscriptions,
    required this.maxPingMs,
    required this.protocolOf,
    required this.subscriptionOf,
    required this.pingOf,
  });

  final RegExp? regex;                 // null = no regex filter
  final Set<String> protocols;         // empty = no protocol filter
  final Set<String> subscriptions;     // empty = no subscription filter; ключ = entry.id или 'custom'
  final int? maxPingMs;                // null = no ping filter

  /// Lookup protocol по tag. null = unknown (cache miss или urltest без selected).
  /// Реализация: см. «Protocol detection» — учитывает urltest group fallback.
  final String? Function(String) protocolOf;

  /// Lookup subscription id по tag. null = custom (UserServer) / unknown.
  final String? Function(String) subscriptionOf;

  /// Lookup ping ms по tag. null = untested (нет в state.lastDelay).
  final int? Function(String) pingOf;

  /// Pure predicate: проходит ли тэг match filter'ы.
  /// Detour exclusion здесь НЕ проверяется — это pool filter в caller.
  bool passes(String tag) {
    if (regex != null && !regex!.hasMatch(tag)) return false;
    if (protocols.isNotEmpty) {
      final p = protocolOf(tag);
      // Unknown protocol при active filter → non-matching (locked decision #12).
      if (p == null || !protocols.contains(p)) return false;
    }
    if (subscriptions.isNotEmpty &&
        !subscriptions.contains(subscriptionOf(tag) ?? 'custom')) {
      return false;
    }
    // Untested (delay==null) ВСЕГДА проходят ping filter (locked decision #11).
    final delay = pingOf(tag);
    if (maxPingMs != null && delay != null && delay > maxPingMs!) return false;
    return true;
  }

  /// Извлечь unique emoji из всех tags (включая detour).
  /// Возвращает в порядке частоты (most-frequent first), потом alphabet.
  static List<String> extractEmojis(List<String> tags);
}
```

### Caller flow (двухфазный)

```dart
// home_screen.dart::_buildNodeList

// Phase 1 — pool filter (detour hide)
final isVisible = (String t) => _showDetourNodes || !t.startsWith(kDetourTagPrefix);
final pool = state.sortedNodes.where(isVisible).toList();

// Phase 2 — match filter (через NodeFilter.passes)
final filter = NodeFilter(
  regex: _regexCompiled,
  protocols: _enabledProtocols,
  subscriptions: _enabledSubscriptions,
  maxPingMs: _maxPingMs,
  protocolOf: (tag) => _protocolOfTag(tag, state),  // см. ниже
  subscriptionOf: (tag) => _subscriptionOfTag(tag, _subController.entries),
  pingOf: (tag) => state.lastDelay[tag],
);
final matching = <String>[];
final nonMatching = <String>[];
for (final tag in pool) {
  if (filter.passes(tag)) matching.add(tag);
  else nonMatching.add(tag);
}

// Render decision
final displayList = _showNonMatching
    ? [...matching, ...nonMatching]
    : matching;
// matching set для O(1) lookup в itemBuilder
final matchingSet = matching.toSet();

// emoji chips: extract из всего pool (или sortedNodes — locked #3)
final emojis = NodeFilter.extractEmojis(state.sortedNodes);

// itemBuilder
itemBuilder: (context, i) {
  final tag = displayList[i];
  // ... derived values как сейчас ...
  return NodeRow(
    // ... existing 14 params ...
    matches: matchingSet.contains(tag),
  );
}
```

### UI layout

```
┌─────────────────────────────────────────┐
│ Nodes (N visible / M total)        ↕ 🎛 │  ← header. ↕ = sort cycle (existing), 🎛 = Icons.tune (expand filter panel)
├─────────────────────────────────────────┤ ↑ panel collapsed
│ [regex pattern_____________________] ✕ │
│ 🇷🇺 🇺🇸 🇩🇪 🇯🇵 ⚡ 👑                    │
│ ☑ vless  ☐ vmess  ☐ trojan  ☐ ss      │
│ ☑ Main  ☐ Backup  ☐ Custom              │
│ Ping ≤ [200] ms                         │
│ ☑ Show detour servers                   │  ← existing toggle переехал из popup
│ ☑ Show non-matching (dimmed)            │  ← новый checkbox, default ON
├─────────────────────────────────────────┤
│ 🇷🇺 Moscow #1 [vless]      ping 23ms   │  ← matching (opacity 1.0)
│ 🇷🇺 SPb #2 [vless]         ping 47ms   │
│ ─────────────                            │  ← divider (только если showNonMatching=ON AND обе группы non-empty)
│ 🇺🇸 NY #1 [vmess]          ping 121ms  │  ← non-matching (opacity 0.4)
│ 🇩🇪 Berlin #1 [trojan]     ping 89ms   │
└─────────────────────────────────────────┘
```

- `Icons.tune` (existing) больше не открывает popup — становится `IconButton` который toggles `_filterPanelExpanded`. Visual hint: color = primary когда filter active (есть regex/protocols/subs/ping выбраны).
- Counters в header: `N visible / M total` — `N = matching.length`, `M = state.sortedNodes.length` (entire pool до Phase 1).
- Clear ✕ в search field — clears regex, doesn't collapse panel.
- Emoji chip tap — append к regex field. Visual feedback: chip pulsates briefly.
- Non-matching dimmed nodes остаются tap-able — filter это visual hint, не lock.

---

## Алгоритмы

### 1. Regex compile + debounce

```dart
void _onRegexChanged(String text) {
  _regexFilter = text;
  _regexDebounceTimer?.cancel();
  _regexDebounceTimer = Timer(const Duration(milliseconds: 300), () {
    setState(() {
      try {
        _regexCompiled = text.isEmpty ? null : RegExp(text, caseSensitive: false);
        _regexValid = true;
      } catch (_) {
        _regexCompiled = null;
        _regexValid = false;
      }
    });
  });
}
```

Empty → no filter. Invalid → no filter + red hint в field.

### 2. Emoji extraction (через `characters` package — built-in Flutter)

```dart
final _emojiRe = RegExp(
  // Extended pictographic + Regional Indicator pair (для флагов 🇷🇺 = RIS+RIS)
  r'(\p{Extended_Pictographic}|\p{Regional_Indicator}\p{Regional_Indicator})',
  unicode: true,
);

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
```

### 3. Protocol detection (учитывает urltest group fallback)

Реальный pattern уже в [home_screen.dart:1851-1852](../../../app/lib/screens/home_screen.dart#L1851) для render label'а:
```dart
final protoType = cache.protoByTag[tag] ??
    (urltestNow != null ? cache.protoByTag[urltestNow] : null);
```

Источник: `state.configCache.protoByTag: Map<String, String>` — proto per tag, заполняется при `saveParsedConfig`. URLTest group selectors сами proto не имеют (это control-узел), но у member nodes proto есть — `urltestNow` указывает на currently selected member.

Helper (живёт в caller-closure):
```dart
// home_screen.dart
String? _protocolOfTag(String tag, HomeState state) {
  final cache = state.configCache;
  final urltestNow = ClashApiClient.urltestNow(state.proxiesJson, tag);
  return cache.protoByTag[tag] ??
      (urltestNow != null ? cache.protoByTag[urltestNow] : null);
}
```

Возвращает `String?` (nullable). Caller передаёт в `NodeFilter.protocolOf` callback.

Поведение при null:
- **No protocol filter** (`_enabledProtocols.isEmpty`) — null игнорируется, всё matching
- **Active protocol filter** — null → non-matching (locked decision #12: «unknown protocol при active filter → non-matching»)

### 4. Subscription detection

```dart
/// Lookup из SubscriptionController.entries: какой subscription
/// (или null если custom UserServer / не tracked) включил эту ноду.
String? _subscriptionOfTag(String tag, List<SubscriptionEntry> entries) {
  for (final e in entries) {
    final list = e.list;
    if (list is SubscriptionServers) {
      if (list.nodes.any((n) => n.tag == tag)) return e.id;
    }
  }
  return null;  // UserServer / unknown — попадают в категорию 'custom'
}
```

Available subscription set для UI chips = `entries.map((e) => (id: e.id, name: e.displayName))` + special «Custom» entry если есть `UserServer`'ы в pool.

В `passes()`:
```dart
if (subscriptions.isNotEmpty &&
    !subscriptions.contains(subscriptionOf(tag) ?? 'custom')) {
  return false;
}
```

`'custom'` — magic ключ для UserServers; в `_enabledSubscriptions` юзер может его toggle через chip «Custom».

### 5. Combine — see `passes()` outline выше

Detour-pass в `passes()` **не входит** — это pool filter (Phase 1 в caller).

---

## UI components

### `_NodeFilterPanel(state, callbacks)`

- `AnimatedSize` для smooth expand/collapse
- Скрыт когда `_filterPanelExpanded == false`
- Composed: `_RegexField` → `_EmojiChipsRow` → `_ProtocolChipsRow` → `_SubscriptionChipsRow` → `_PingFilterField` → existing «Show detour servers» checkbox → `_ShowNonMatchingCheckbox`

### `_RegexField(text, onChanged, valid)`

- Compact `TextField` (height ~36)
- `errorText: valid ? null : 'Invalid regex'`
- Trailing `IconButton(Icons.clear)` если `text.isNotEmpty`
- `onChanged: _onRegexChanged` (debounced)

### `_EmojiChipsRow(emojis, onTap)`

- `SingleChildScrollView(scrollDirection: horizontal)` с `Chip`'ами
- `Chip(label: Text(emoji, fontSize: 16))` height ~28
- Tap → callback вставляет emoji в regex field

### `_ProtocolChipsRow(available, enabled, onToggle)`

- `Wrap` с `FilterChip`'ами
- Available — список unique protocols из pool (computed in caller: `pool.map(protocolOf).whereType<String>().toSet()`)
- onSelected → toggle в `_enabledProtocols`

### `_SubscriptionChipsRow(available, enabled, onToggle)`

- `Wrap` с `FilterChip`'ами
- Available — список `(id, displayName)` пар из `_subController.entries` + special «Custom» если есть UserServer в pool
- onSelected → toggle в `_enabledSubscriptions` (id или 'custom')

### `_PingFilterField(value, onChanged)`

- Compact `Row`: `Text("Ping ≤")` + `TextField(keyboardType: number)` + `Text("ms")` + clear button
- `onChanged` → debounce 300ms → парсит int → setState `_maxPingMs`
- Empty input или non-parseable → `_maxPingMs = null` (filter off)
- Hint в field: «200»

### `_ShowNonMatchingCheckbox(value, onChanged)`

- `CheckboxListTile(dense: true, contentPadding: EdgeInsets.zero)` с label «Show non-matching (dimmed)»
- **Default `value: true`** → non-matching внизу с opacity 0.4
- Toggle OFF → non-matching hidden (классический filter behaviour)

### `Icons.tune` header button

- Заменяет existing `PopupMenuButton(Icons.tune)` на `IconButton(Icons.tune)`
- `onPressed: () => setState(() => _filterPanelExpanded = !_filterPanelExpanded)`
- `color: _isFilterActive ? cs.primary : null` — visual hint когда есть active filter (regex/protocols/subs/ping всё ненулевое)

### `NodeRow` (модификация)

- Constructor: + `required this.matches`
- `build()`: оборачивает existing content в `Opacity(opacity: matches ? 1.0 : 0.4, child: ...)`
- Single source of opacity. Caller передаёт `matches: bool`, не знает о 0.4.

---

## Test plan

### Unit (`test/screens/home/node_filter_test.dart`)

1. `extractEmojis` — RIS flags (🇷🇺 single grapheme), pictographic (⚡), без latin false-positives
2. `extractEmojis` — frequency sort (most-frequent first)
3. `passes` — empty filter (regex=null, protocols={}, subscriptions={}, maxPingMs=null) → true для любого tag'а
4. `passes` — regex match — case-insensitive
5. `passes` — regex non-match → false
6. `passes` — protocol filter exclusive: known proto не в set → false; unknown proto при active filter → false; unknown при no filter → true
7. `passes` — subscription filter с UserServer (subscriptionOf returns null) → попадает в category 'custom'
8. `passes` — ping filter: delay ≤ N → true, delay > N → false, delay=null → true (untested always pass)
9. `passes` — ping filter off (maxPingMs=null) → true даже для delay=99999
10. `passes` — AND combine: regex match + protocol fail → false
11. `passes` — НЕ проверяет detour exclusion (это caller responsibility); `tag.startsWith(kDetourTagPrefix)` не влияет на predicate

### Widget

1. Filter panel hidden by default — verify только header rendered
2. Tap expand → AnimatedSize разворачивается, видны 7 controls
3. Type invalid regex → red hint, filter не применяется (всё matching)
4. Tap emoji chip → text field updated, debounce → setState
5. Toggle protocol chip → list re-splits live (без debounce для chips)
6. Empty pool → emoji row hidden (zero chips)
7. NodeRow с `matches: false` → `Opacity(opacity: 0.4)` обёртка present

### E2E на устройстве

1. App с ~50 nodes from 5 subscriptions → emoji chips show 🇷🇺 / 🇺🇸 / 🇩🇪 / 🇯🇵
2. Tap 🇷🇺 → 8 matching сверху, 42 non-matching внизу dimmed (showNonMatching ON)
3. Toggle protocol chip vless → 5 matching (RU+vless)
4. Toggle subscription chip «Main» → 3 matching (RU+vless+Main)
5. Set `Ping ≤ 100` → 2 matching (RU+vless+Main+ping ≤ 100); 1 untested тоже matching (passes despite ping filter)
6. Toggle «Show detour servers» OFF → detour ноды **отсутствуют** в list вообще (Phase 1 pool filter)
7. Toggle «Show non-matching» OFF → non-matching убираются из list (но всё остальное остаётся)
8. Clear regex → 8 matching (только protocol+subscription+ping)
9. Collapse panel via `Icons.tune` → controls hidden, filter всё равно применяется visually
10. Restart app → filter сброшен (per-session)

---

## Implementation outline

| Файл | Что |
|---|---|
| `app/lib/screens/home/node_filter.dart` NEW | `class NodeFilter` с `passes(tag) → bool` + static `extractEmojis(List<String>)`. Lookup callbacks (`protocolOf`/`subscriptionOf`/`pingOf`) — closure-параметры. **Не знает про detour.** |
| `app/lib/widgets/node_row.dart` | + `bool matches` param + `Opacity(opacity: matches ? 1.0 : 0.4)` wrapper в `build()` (single source) |
| `app/lib/screens/home/filter_widgets.dart` NEW | `_NodeFilterPanel`, `_RegexField`, `_EmojiChipsRow`, `_ProtocolChipsRow`, `_SubscriptionChipsRow`, `_PingFilterField`, `_ShowNonMatchingCheckbox` |
| `app/lib/screens/home_screen.dart` | + state fields + замена `PopupMenuButton(Icons.tune)` → `IconButton` (expand toggle) + render panel в node list header + двухфазный split в `_buildNodeList` + helper `_protocolOfTag` / `_subscriptionOfTag` (closure для NodeFilter) |
| `app/test/screens/home/node_filter_test.dart` NEW | Unit tests на predicate (11 cases) |
| `docs/spec/features/048 home-node-filters/spec.md` | этот spec |
| `CHANGELOG.md` Unreleased | Added entry |

Объём ~300 строк production + ~150 testов.

---

## Optional extract during implementation — §068

Spec [`tasks/068 — extract NodeViewItem`](../../tasks/068-node-view-item-extract.md) описывает refactor `NodeRow(14 args)` → `NodeRow(item: NodeViewItem)`. **Делается внутри этого PR**, не отдельной таской, **если** во время реализации сработает хотя бы один trigger:

1. **itemBuilder раздулся** — после добавления filter logic + detour + urltest detection + proto detection + matches вычисления каждая итерация >50 строк локальных derived values. Чище отделить «собрали snapshot строки» от «нарисовали».

2. **Появился второй call-site** `NodeRow` — другой screen (Stats / Subscriptions detail / Routing) хочет переиспользовать widget.

Если ни один trigger не сработал — `NodeRow(matches: bool, ...14 args)` остаётся как есть. YAGNI.

Решение принимается во время implementation. Если extract сделан — это часть §048 commit'а, в commit message упомянуть «closes §068».

---

## Risks

| Риск | Митигация |
|---|---|
| Regex performance | Compile один раз, `hasMatch` O(n*m). Для 200 nodes / 30-char pattern < 1ms. |
| Emoji extraction false-positives | Curated `_emojiRe` (Extended_Pictographic + Regional_Indicator pair). Unit tests на flag emoji + latin. |
| Protocol detection fail (`protoByTag[tag] == null`) | Locked decision #12: при active proto filter → non-matching. Без filter → matching (untouched). |
| Filter panel занимает экран | Default collapsed. Expanded ~140px (regex 36 + emoji 32 + protocol 48 + sub 32 + ping 36 + 2 checkbox 40 — `AnimatedSize` smooth). Юзер collapse в любой момент. |
| Non-matching dimmed nodes остаются tap-able | By design — filter это visual hint, не lock. Юзер может коннектиться к серой ноде. |
| Regex match emoji literal | Dart regex с flag chars в matches работает. Тесты на flag patterns (`🇷🇺.*Moscow`). |
| Detour exclusion смешан с filter | Двухфазная модель: detour — pool filter в caller, `NodeFilter.passes` не знает о detour. Test case #11 проверяет. |

---

## Dependencies

- `characters` — built-in Flutter (Unicode grapheme clusters). Уже доступен.
- Никаких новых pub packages.
