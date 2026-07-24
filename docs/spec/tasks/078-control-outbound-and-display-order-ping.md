# 078 — Control outbounds always visible + ping test в порядке отображения

| Поле | Значение |
|------|----------|
| Статус | ✅ Реализовано (позже) — `runMassUrltest({order})` в порядке отображения + control-outbound pass-through. Шапка «In progress» устарела. |
| Дата | 2026-06-08 |
| Тип | fix (UX) + small refactor |
| Зависимости | §048 (NodeFilter), §077 (ambiguity-aware subscription lookup), §070 (sort options), §071 (manual reorder). |
| Связанные | `app/lib/screens/home_screen.dart` (pool + filter split, runMassUrltest call-site), `app/lib/controllers/home_controller.dart` (`runMassUrltest`). |

## Триггер

Юзер тестит §077 multi-match fix, и подмечает два пункта:

1. **`direct` / `auto` исчезают при включённом фильтре.** Control outbounds (`direct-out`, `kAutoOutboundTag = '✨auto'`, urltest-group selectors) попадают в `pool` через `_viewSortedNodes(state)`, проходят через `NodeFilter.passes`, получают `subscriptionsOf() == {}` (не принадлежат ни одной подписке) и `protocolOf() == null` (тип в `_skipTypes`). Любой активный chip-filter (subscription/protocol) отбраковывает их → они dim'ятся вместе с не-matching нодами. Юзеру нужно чтобы они **всегда** были full-opacity, независимо от фильтра, потому что это control-узлы, а не «нода из неизвестной подписки».

2. **«Ping all» bypass'ит сортировку + фильтр.** `HomeController.runMassUrltest` iterates `_state.nodes` (raw config-order). UI кнопка пингует ноды не в том порядке, в котором юзер их видит. Особенно неприятно: при активном filter с `showNonMatching=false` отображается, скажем, 30 нод, а пинг идёт по всем 500.

Audit (workflow `verify-077-multi-match`) подтвердил pункт 1 как finding #14 «Pool INCLUDES control outbounds» с дополнительными последствиями:
- `hasCustom = pool.any((t) => _subscriptionsOfTag(t).isEmpty)` срабатывает на `direct-out`/`auto` → 'Custom' chip отображается **даже когда нет UserServer'ов**.
- При выборе 'Custom' chip control outbounds passing'ат filter как «custom subscription» — семантически неверно.

## Цель

- Control outbounds (selectors, urltest groups, direct, block, dns proxies) **всегда matching** в home node list независимо от состояния фильтров.
- 'Custom' chip отображается **только** когда в pool реально есть UserServer (или прокси-нода без атрибуции).
- 'Ping all' iterates **отображаемый список** в порядке отображения, не raw config-order.

## Не в скопе

- **NodeFilter pure helper изменения** — `passes()` остаётся без знания про control outbounds. Special-case логика живёт в caller (home_screen), как с detour pool filter. Тот же принцип clean separation как в §048.
- **`runMassUrltest` cancel semantics** — без изменений (toggle re-tap cancel).
- **Пинг для skipped control outbounds внутри order** — если caller прокинет control outbound в `order`, `clash.delay(tag)` для selector/urltest вернёт error (-1), как сейчас для невалидных тегов. Не блокер.
- **Persisted filter state** — per-session как сейчас.

---

## Текущее состояние

### Pool composition (home_screen.dart:2199-2202)

```dart
final allTags = _viewSortedNodes(state);                // state.sortedNodes
final pool = _showDetourNodes
    ? allTags
    : allTags.where((t) => !t.startsWith(kDetourTagPrefix)).toList();
```

`state.sortedNodes` ← `_computeSortedNodes` (home_state.dart:170-199) — содержит `direct-out`, `kAutoOutboundTag`, прокси-ноды, detour-prefixed outbounds. **Pool не различает control vs payload outbounds.**

### Filter split (home_screen.dart:2225-2239)

```dart
final matching = <String>[];
final nonMatching = <String>[];
for (final tag in pool) {
  if (filter.passes(tag)) {
    matching.add(tag);
  } else {
    nonMatching.add(tag);
  }
}
```

`direct-out` → `filter.passes`:
- regex active → возможно false (если pattern не матчит 'direct-out')
- protocols active + non-empty → `protocolOf('direct-out')` = null → false
- subscriptions active + non-empty → `subscriptionsOf('direct-out')` = {} → effective={'custom'} → если 'custom' chip ON, true (semantically wrong); иначе false
- ping active → delay==null → true (locked decision #11)

Net effect: при любом активном filter (protocol/subscription) direct-out падает в nonMatching → dim.

### hasCustom (home_screen.dart:2258-2260)

```dart
final hasCustom = pool.any((t) => _subscriptionsOfTag(t).isEmpty);
if (hasCustom) subOptions.add(('custom', 'Custom'));
```

`direct-out`/`auto` дают empty Set → hasCustom=true даже без UserServer'ов.

### runMassUrltest (home_controller.dart:889-906)

```dart
Future<void> runMassUrltest() async {
  ...
  if (_state.nodes.isEmpty) return;
  ...
  final nodes = List<String>.from(_state.nodes);   // raw config order, все ноды
  final busyMap = {for (final tag in nodes) tag: '…'};
  _emit(_state.copyWith(lastDelay: <String, int>{}, pingBusy: busyMap));
  ...
}
```

`_state.nodes` это `entry['all']` из Clash API (порядок sing-box config + регистрации). Не учитывает sortMode / manualOrder / pinned / filter.

---

## Целевое состояние

### 1. `_isControlTag` helper в home_screen

Detection из `state.proxiesJson`:

```dart
/// True если outbound с этим tag'ом — control (selector / urltest /
/// direct / block / dns), не реальная payload-нода. Использует
/// proxiesJson из Clash API как source-of-truth (sing-box знает типы
/// своих outbound'ов лучше чем мы).
static const _controlProxyTypes = <String>{
  'selector', 'urltest', 'direct', 'block', 'dns',
};

bool _isControlTag(String tag, HomeState state) {
  final pmap = state.proxiesJson['proxies'];
  if (pmap is! Map<String, dynamic>) return false;
  final entry = pmap[tag];
  if (entry is! Map<String, dynamic>) return false;
  final type = (entry['type'] as String?)?.toLowerCase() ?? '';
  return _controlProxyTypes.contains(type);
}
```

### 2. Filter split с control-pass-through

```dart
final matching = <String>[];
final nonMatching = <String>[];
for (final tag in pool) {
  // Control outbounds (direct-out / ✨auto / etc.) всегда matching —
  // фильтр про payload ноды, control не на уровне tag'а.
  if (_isControlTag(tag, state) || filter.passes(tag)) {
    matching.add(tag);
  } else {
    nonMatching.add(tag);
  }
}
```

### 3. hasCustom с control-exclusion

```dart
// 'Custom' chip отображается только если в pool есть **payload** тэги
// с empty subscriptionsOf — то есть UserServer'ы. Control outbounds
// тоже дают empty Set, но они в свою категорию.
final hasCustom = pool.any((t) =>
    !_isControlTag(t, state) && _subscriptionsOfTag(t).isEmpty);
```

### 4. `runMassUrltest({List<String>? order})`

```dart
/// Mass URLTest на нодах активной группы — параллельные `clash.delay`
/// с concurrency cap. Повторный вызов во время running — cancel.
///
/// [order] — optional список тэгов в желаемом порядке пинга. Если не
/// передан, используется `_state.nodes` (raw config-order). UI кнопка
/// передаёт `displayList` (sort + manual + pinned + filter) → пинг идёт
/// **в порядке отображения**, что юзер ожидает.
Future<void> runMassUrltest({List<String>? order}) async {
  final clash = _clash;
  if (clash == null) return;
  final nodes = List<String>.from(order ?? _state.nodes);
  if (nodes.isEmpty) return;
  // ...rest unchanged, just uses `nodes` instead of List.from(_state.nodes)
}
```

UI call-site (home_screen.dart:1071):

```dart
// before:
unawaited(_controller.runMassUrltest());
// after:
unawaited(_controller.runMassUrltest(order: displayList));
```

Где `displayList` — финальный список который рендерится в `ListView.itemBuilder` (`matching + nonMatching` если showNonMatching=ON, иначе только `matching`).

⚠ **Subtle**: control outbounds в `displayList` тоже пингаются — `clash.delay('direct-out')` валиден (sing-box возвращает реальную latency), `clash.delay('✨auto')` обычно возвращает error т.к. это selector. Не блокер: error → delay=-1 → UI показывает крестик.

---

## Преимущества

1. **Корректность under filter**: direct/auto **всегда** видны, юзер не теряет «emergency direct switch» когда включён subscription chip.
2. **'Custom' chip**: появляется только при наличии реальных UserServer'ов → меньше шума в filter UI.
3. **Predictable ping order**: пинг идёт по visible nodes в visible order. Юзер видит как заполняются результаты сверху вниз, как и ожидает.
4. **Меньше обработки невидимого**: при активном filter + `showNonMatching=false` пингаются только matching ноды, не всё подряд.
5. **Clean separation**: NodeFilter остаётся pure (не знает про control). Special-case логика — caller responsibility, как detour pool filter.

---

## Файлы

| Файл | Изменение |
|---|---|
| `app/lib/screens/home_screen.dart` | + `_isControlTag(tag, state)` helper. Filter split добавляет early-pass на control. `hasCustom` exclude'ит control. `runMassUrltest` call-site передаёт `displayList`. |
| `app/lib/controllers/home_controller.dart` | `runMassUrltest({List<String>? order})` — backward-compat optional param. Используется `order ?? _state.nodes`. |
| `docs/spec/tasks/078-control-outbound-and-display-order-ping.md` (этот) | NEW spec. |
| `CHANGELOG.md` | Entry под `### Fixed` (`v1.9.1`). |

---

## Tests

- **Manual smoke** (no unit test для UI):
  1. Active subscription chip (e.g. RU): direct-out + ✨auto remain full-opacity, видны вверху списка.
  2. 'Custom' chip визибилити: с одним SubscriptionServers и без UserServer'ов — chip отсутствует. После добавления UserServer'a — появляется.
  3. Ping all с активным filter: ноды пингаются в порядке `displayList`, не raw config-order. Виден прогресс сверху вниз.
  4. Cancel ping (re-tap кнопки) — работает как раньше.
- Существующие тесты `node_filter_test.dart` без изменений (NodeFilter контракт не меняется).

---

## Acceptance criteria

- [ ] `direct-out` / `✨auto` / любой selector/urltest имеют `matches=true` при любом filter state.
- [ ] 'Custom' chip отображается только при наличии payload-нод с empty `subscriptionsOf` (= UserServer'ы), control outbounds его не триггерят.
- [ ] `runMassUrltest(order: [...])` iterates по переданному списку в его порядке.
- [ ] UI button «Ping all» передаёт `displayList` (sorted + filtered порядок отображения).
- [ ] Без `order` параметра — backward-compat: iterates `_state.nodes` как раньше.
- [ ] `flutter analyze` clean, full test suite зелёный (regression-free).
