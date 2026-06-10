# 077 — Node filter: subscription chip не мэтчит подписки с tagPrefix

| Поле | Значение |
|------|----------|
| Статус | Released в v1.9.1 |
| Дата | 2026-06-07 |
| Тип | fix (behaviour bug) + API rename (NodeFilter contract) |
| Зависимости | §048 (home node filters), §073 (server_list_build `_withPrefix`). |
| Связанные | `home_screen.dart::_subscriptionsOfTag`, `home/subscription_lookup.dart::subscriptionsOfTag`, `server_list_build.dart::_withPrefix`, `node_filter.dart::passes`. |

## Триггер (incident 2026-06-07)

Юзер: «в фильтре по nodes на главной не работает фильтр по подпискам. Если
у подписки есть префикс то поиск не срабатывает».

Воспроизведение:
1. Подписка с `tag_prefix = '🇷🇺 RU'` и нодами (e.g. node.tag = `'M1'`).
2. На home tap по filter icon → раскрыть subscription chips → выбрать данную подписку.
3. **Ожидание**: ноды этой подписки помечаются `matches=true`, остальные → opacity 0.4.
4. **Факт**: ВСЕ ноды этой подписки помечены `matches=false` (dimmed) — фильтр не находит ни одну.

## Root cause

`server_list_build.dart::_withPrefix` строит финальный display-тэг для каждого
outbound'а:

```dart
String _withPrefix(String base) =>
    tagPrefix.isEmpty ? base : '$tagPrefix $base';
```

То есть в `state.nodes` хранится **prefixed-form** (`'🇷🇺 RU M1'`), а
`SubscriptionServers.nodes[i].tag` — **bare** (`'M1'`).

`home_screen.dart::_subscriptionOfTag` (lookup, который feed'ит
`NodeFilter.subscriptionOf`) сравнивал bare:

```dart
String? _subscriptionOfTag(String tag) {
  for (final e in _subController.entries) {
    final list = e.list;
    if (list is SubscriptionServers) {
      if (list.nodes.any((n) => n.tag == tag)) return e.id;  // ← bug
    }
  }
  return null;
}
```

`n.tag == tag` для `n.tag='M1'`, `tag='🇷🇺 RU M1'` → всегда false → все ноды
непрефиксованных подписок возвращали `null` (категория `'custom'`).
NodeFilter с активным `subscriptions = {sub-id}` отбраковывал их →
все dimmed.

При `tagPrefix == ''` баг невидим (bare-form совпадает с display-form).

## Фикс

Два шага:

### 1. Сравнивать prefixed-form (основной bug)

`_withPrefix` строит `'$tagPrefix $base'`. Lookup должен делать то же:

```dart
final base = prefix.isEmpty ? n.tag : '$prefix ${n.tag}';
if (tag == base) ...
```

### 2. Ambiguity-aware lookup (collision-suffix)

`_BuildCtx.allocateTag` добавляет `-1/-2/...` когда `'prefix base'`
коллизит с уже зарезервированным тэгом (control outbounds, другая нода,
**другая подписка с тем же prefix+name**). Heuristic «считаем `base-N`
принадлежащим тому же entry где есть `base`» при двух подписках с
пересечением имён даёт **deceptive disambiguation** — возвращаем первую
итерируемую subscription'у, реальный source может быть другой.

Решение: **возвращаем Set всех candidates**. Нода с коллизионным тэгом
явно отображается во **всех** chip'ах подписок которые могли её создать.
Юзер видит честную ambiguity вместо arbitrary tie-break'а.

```dart
Set<String> _subscriptionsOfTag(String tag) {
  final result = <String>{};
  for (final e in _subController.entries) {
    final list = e.list;
    if (list is! SubscriptionServers) continue;
    final prefix = list.tagPrefix;
    for (final n in list.nodes) {
      final base = prefix.isEmpty ? n.tag : '$prefix ${n.tag}';
      if (tag == base) { result.add(e.id); break; }
      // collision-suffix 'base-N' (см. _BuildCtx.allocateTag)
      if (tag.length > base.length + 1 &&
          tag.startsWith(base) &&
          tag.codeUnitAt(base.length) == 0x2D /* '-' */) {
        final rest = tag.substring(base.length + 1);
        if (rest.isNotEmpty &&
            rest.codeUnits.every((c) => c >= 0x30 && c <= 0x39)) {
          result.add(e.id);
          break;
        }
      }
    }
  }
  return result;
}
```

NodeFilter contract обновляется: `subscriptionOf: String? Function(String)`
→ `subscriptionsOf: Set<String> Function(String)`. Predicate:

```dart
if (subscriptions.isNotEmpty) {
  final candidates = subscriptionsOf(tag);
  final effective = candidates.isEmpty ? const {'custom'} : candidates;
  if (!effective.any(subscriptions.contains)) return false;
}
```

То же простое set algebra — нода passes если хоть одна подписка-кандидат
в выбранных chip'ах. UserServer (`candidates.isEmpty`) → `'custom'`
category, без изменений.

## Не в скопе

- **Reverse-map через builder (§078 honest fix)** — отвергнут в пользу
  ambiguity-aware lookup'а. Builder знает кто реально получил `-N` suffix
  (детерминированный порядок iteration'а), но **семантически** при
  коллизии имён обе подписки equally "claim" ноду — лучше показать в
  обоих фильтрах чем deceptive disambiguation.
- **Кэширование `tag → subscriptionsOf` map** — будущая оптимизация.
  Сейчас каждый filter pass вызывает lookup per tag → O(N×M)
  (N=tags в pool, M=sum(nodes) по entries). На реальных размерах
  (≤500 nodes, ≤10 subscriptions) latency ≤ms, не блокер.
- **UserServer (`'custom'` category)** — не задевается. `_subscriptionsOfTag`
  возвращает пустой Set для них, caller mappит empty → `'custom'`.
- **Migration / backup** — schema не меняется.
- **Изменение order'а chip pool'а** — chip iteration по entries (порядок
  в `_subController.entries`) без изменений.

## Известное ограничение (audit scenario G)

Эвристика collision-suffix (`'base-<digits>'`) не различает **реальную**
коллизию от `_BuildCtx.allocateTag` (когда builder добавил `-N` чтобы
избежать столкновения тэгов) от **literal node tag**, который случайно
имеет shape `'something-N'`.

Пример false-positive: Sub A с одной нодой literally названной `'M1-1'`
(без prefix); Sub B с нодой `'M1'` (без prefix). Builder выдаёт `'M1-1'`
(от A) и `'M1'` (от B). Lookup `'M1-1'`:
- A: exact match `'M1-1' == 'M1-1'` → add A.id
- B: collision-suffix `'M1-1'.startsWith('M1-')`, rest=`'1'` digit-only → add B.id

Net result: `{A, B}` — A correct, B false-positive (B's node 'M1' не
произвёл tag 'M1-1'; B's display-tag это 'M1', а не 'M1-1').

Builder allocation order не персистится в `state.nodes` → различить
literal-suffix от collision-allocation без второго прохода через builder
невозможно. Acceptable trade-off: UX impact = superset в chip filter
(нода Sub A's literal 'M1-1' покажется matching в обоих chip'ах) —
честнее чем deceptive disambiguation.

Полное устранение требует §078 honest-fix (builder сохраняет reverse-map
в config или separately). Отвергнут в §077 в пользу простоты + признания
неизбежной ambiguity для actual collision case.

## Файлы

- `app/lib/screens/home/subscription_lookup.dart` — pure helper
  `subscriptionsOfTag(tag, entries)` с prefix reconstruction +
  collision-suffix detection + disabled subs skip (extracted из
  home_screen для testability, audit blocker #1).
- `app/lib/screens/home_screen.dart` — `_subscriptionsOfTag` теперь
  тонкая обёртка над helper'ом.
- `app/lib/screens/home/node_filter.dart` — NodeFilter contract
  `subscriptionOf: String?` → `subscriptionsOf: Set<String>`. Predicate
  использует intersection (`effective.any(subscriptions.contains)`);
  empty Set candidates → `'custom'` fallback.
- `app/test/screens/home/subscription_lookup_test.dart` — 18 unit tests
  на pure helper (prefix, collision-suffix digit-only, multi-match
  ambiguity, UserServer empty, disabled subs skip, edge cases).
- `app/test/screens/home/node_filter_test.dart` — signature update +
  тесты для collision, multi-chip, mixed `{custom, sub}`, filter-off.
- `docs/spec/tasks/077-subscription-filter-with-prefix.md` (этот файл).
- `CHANGELOG.md` — entry под `### Fixed` (v1.9.1).

## Acceptance criteria

- [x] Подписка с `tagPrefix='🇷🇺 RU'`: chip-фильтр отображает её ноды как
      matching (full opacity), не-matching — dim.
- [x] Подписка с пустым `tagPrefix`: поведение без изменений (regression-free).
- [x] UserServer (custom): попадает в `'custom'` chip; chip-фильтр работает.
- [x] Mixed (несколько подписок, разные prefix): включение chip'а одной →
      ровно её ноды matching.
- [x] **Collision** (две подписки с одинаковым prefix+name): нода `'base'`
      и нода `'base-1'` обе попадают в matching при выборе chip'а **любой**
      из двух подписок (ambiguity-aware).
- [x] Unit tests `node_filter_test.dart`: signature `subscriptionsOf` +
      collision tests + multi-chip + mixed-custom + filter-off.
- [x] Pure helper `subscription_lookup.dart` extracted + 18 unit tests
      (audit blocker #1 resolved).

## Manual verification

После APK install:
1. Add subscription with `tagPrefix='🇷🇺 RU'`, refresh → nodes appear.
2. Home → tap filter icon → expand subscription chips → tap chip with this sub.
3. Expected: подписочные ноды full opacity, остальные dim.
4. Tap chip again → off → all opacity 1.0.
5. Test со вторым tag-prefix subscription — chip caters только её.
