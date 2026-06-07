# 077 — Node filter: subscription chip не мэтчит подписки с tagPrefix

| Поле | Значение |
|------|----------|
| Статус | In progress (v1.9.1) |
| Дата | 2026-06-07 |
| Тип | fix (behaviour bug) |
| Зависимости | §048 (home node filters), §073 (server_list_build `_withPrefix`). |
| Связанные | `home_screen.dart::_subscriptionOfTag`, `server_list_build.dart::_withPrefix`, `node_filter.dart::passes`. |

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

Сравнивать prefixed-form, идентично тому что строит `_withPrefix`:

```dart
String? _subscriptionOfTag(String tag) {
  for (final e in _subController.entries) {
    final list = e.list;
    if (list is! SubscriptionServers) continue;
    final prefix = list.tagPrefix;
    for (final n in list.nodes) {
      final base = prefix.isEmpty ? n.tag : '$prefix ${n.tag}';
      if (tag == base) return e.id;
      // collision-suffix от `allocateTag`: 'base-1', 'base-2', ...
      if (tag.length > base.length + 1 &&
          tag.startsWith(base) &&
          tag.codeUnitAt(base.length) == 0x2D /* '-' */) {
        final rest = tag.substring(base.length + 1);
        if (rest.isNotEmpty &&
            rest.codeUnits.every((c) => c >= 0x30 && c <= 0x39)) {
          return e.id;
        }
      }
    }
  }
  return null;
}
```

Collision-suffix handled best-effort: `_BuildCtx.allocateTag` добавляет
`-1/-2/...` при коллизии base'а с уже зарезервированным тэгом (control
outbounds или другая нода). Считаем такие `'base-N'` принадлежащими тому
же entry где есть `base` — единственная безопасная эвристика без второй
прогонки через builder.

## Не в скопе

- **Кэширование `tag → subscriptionId` map** — будущая оптимизация. Сейчас
  каждый filter pass вызывает `_subscriptionOfTag` per tag → O(N×M) (N=tags
  в pool, M=sum(nodes) по entries). На реальных размерах (≤500 nodes,
  ≤10 subscriptions) latency ≤ms, не блокер.
- **UserServer (`'custom'` category)** — не задевается. `_subscriptionOfTag`
  возвращает null для них как и было, caller mappит null → `'custom'`.
- **Migration / backup** — schema не меняется.
- **NodeFilter (pure helper)** — bug был в supplier function, не в predicate.
  Unit tests `node_filter_test.dart` всё ещё валидны.

## Файлы

- `app/lib/screens/home_screen.dart` — `_subscriptionOfTag` сравнивает
  prefixed-form + handle collision-suffix.
- `docs/spec/tasks/077-subscription-filter-with-prefix.md` (этот файл).
- `CHANGELOG.md` — entry под `### Fixed` (v1.9.1).

## Acceptance criteria

- [ ] Подписка с `tagPrefix='🇷🇺 RU'`: chip-фильтр отображает её ноды как
      matching (full opacity), не-matching — dim.
- [ ] Подписка с пустым `tagPrefix`: поведение без изменений (regression-free).
- [ ] UserServer (custom): попадает в `'custom'` chip; chip-фильтр работает.
- [ ] Mixed (несколько подписок, разные prefix): включение chip'а одной →
      ровно её ноды matching.

## Manual verification

После APK install:
1. Add subscription with `tagPrefix='🇷🇺 RU'`, refresh → nodes appear.
2. Home → tap filter icon → expand subscription chips → tap chip with this sub.
3. Expected: подписочные ноды full opacity, остальные dim.
4. Tap chip again → off → all opacity 1.0.
5. Test со вторым tag-prefix subscription — chip caters только её.
