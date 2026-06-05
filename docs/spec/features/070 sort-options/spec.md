# 070 — Sort options long-press menu

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-06-05 |
| Зависимости | `NodeSortMode` (home_state.dart), `cycleSortMode` (home_controller.dart), §048 (filter panel — соседняя icon-кнопка в node header) |
| Связанные | §071 (manual node reorder — отдельная фича, добавляет `NodeSortMode.manual`) |
| Триггер | Юзер просит конфигурируемость sort'а. До §070 sort cycle'ил Default→Ping→A-Z, `direct-out` + `✨auto` пиннились сверху hardcoded'ом, `latencyAsc` re-sort'ил список на каждом manual ping'е (ряд под пальцем юзера прыгал). |

## Цель

Long-press на sort IconButton открывает popup menu с 3 toggle'ами:

1. **Pin DIRECT to top** (default ON) — `direct-out` сверху отдельно от обычного sort.
2. **Pin AUTO to top** (default ON) — `✨auto` сверху отдельно от обычного sort.
3. **Re-sort on manual ping** (default ON) — пересчитывать порядок когда manual single-node URLTest обновляет `lastDelay[tag]`.

Yellow dot indicator на sort button когда хотя бы одна опция non-default.

## Не в скопе

- Persistence через рестарт — toggle'ы per-session in-memory (consistency с §048 filter state и `_showDetourNodes`). Persist = миграция storage, отдельный scope.
- Изменение sort cycle (`cycleSortMode`) — порядок modes остаётся.
- Manual reorder через drag — §071, отдельная фича.
- Backup format — sort options не входят в `lxbox-backup-*.json`.

---

## Текущее состояние

```
NodeSortMode { defaultOrder, latencyAsc, nameAsc }
  └─ cycleSortMode → tap sort button перебирает по кругу

HomeState._computeSortedNodes:
  if defaultOrder → return nodes;          // pin не применяется
  pinnedOrder = ['direct-out', '✨auto']    // HARDCODED, всегда применяется
  pinned = nodes ∩ pinnedOrder
  rest = nodes \ pinnedOrder
  rest.sort(latencyAsc | nameAsc)
  return [...pinned, ...rest]

UI: IconButton(onPressed: cycleSortMode, icon: sortMode.icon)
  └─ tap = cycle; long-press = nothing
```

Manual ping (`runNodeUrltest(tag)`) → `_emit(copyWith(lastDelay: {...prev, tag: ms}))`
→ новый HomeState → новый `late final sortedNodes` → re-sort → строка прыгает.

---

## Целевое состояние

### HomeState — 3 toggle поля + 1 counter

```dart
class HomeState {
  // ...existing...
  final bool pinDirect;            // default true
  final bool pinAuto;              // default true
  final bool resortOnManualPing;   // default true (старое поведение)
  final int pingBatchGen;          // default 0, bump на batch / group / config rebuild
}
```

`_computeSortedNodes` использует `pinDirect` / `pinAuto`:

```dart
final pinnedOrder = <String>[
  if (pinDirect) 'direct-out',
  if (pinAuto) kAutoOutboundTag,
];
```

`resortOnManualPing` **НЕ** читается в HomeState — он управляет UI-cache (см. ниже).
`pingBatchGen` — passive counter, тоже только для UI-cache invalidation.

### HomeController — `pingBatchGen` bump в 4 точках

| Метод | Bump? | Почему |
|---|---|---|
| `runNodeUrltest(tag)` | **нет** | manual single ping — cache держится |
| `runMassUrltest()` (per-result emit во время batch) | нет | в процессе — не дёргать порядок |
| `runMassUrltest()` (финал, batch завершён) | **да** | один re-sort после batch |
| `runGroupUrltest(groupTag)` | **да** | re-sort после group URLtest |
| `setActiveGroup` / group switch | **да** | новый pool — sort заново |
| `saveParsedConfig` при tunnelUp | **да** | новый config — sort заново |

Новые методы:

```dart
void setPinDirect(bool v) → _emit(copyWith(pinDirect: v));
void setPinAuto(bool v) → _emit(copyWith(pinAuto: v));
void setResortOnManualPing(bool v) → _emit(copyWith(resortOnManualPing: v));
```

### UI-cache (`_HomeScreenState`) — frozen sort при `resortOnManualPing == false`

```dart
List<String>? _cachedSorted;
({NodeSortMode mode, int gen, int nodesLen, bool pinD, bool pinA})? _cachedKey;

List<String> _viewSortedNodes(HomeState s) {
  if (s.resortOnManualPing) {
    // ON: cache не используется, всегда свежий sort.
    _cachedKey = null;
    _cachedSorted = null;
    return s.sortedNodes;
  }
  final key = (
    mode: s.sortMode,
    gen: s.pingBatchGen,
    nodesLen: s.nodes.length,
    pinD: s.pinDirect,
    pinA: s.pinAuto,
  );
  if (key == _cachedKey && _cachedSorted != null) {
    // sanity: проверяем что все cached tags ещё в pool (защита от
    // ноды удалённой из подписки между bump'ами).
    if (_cachedSorted!.every(s.nodes.contains)) return _cachedSorted!;
  }
  _cachedKey = key;
  _cachedSorted = List<String>.unmodifiable(s.sortedNodes);
  return _cachedSorted!;
}
```

В `_buildNodeList` заменить `state.sortedNodes` → `_viewSortedNodes(state)`.

### UI — long-press menu + yellow dot

`_buildNodesHeader`:

```dart
GestureDetector(
  onTap: state.nodes.isEmpty ? null : _controller.cycleSortMode,
  onLongPress: state.nodes.isEmpty ? null : () => _showSortOptionsMenu(context),
  child: Stack(
    clipBehavior: Clip.none,
    children: [
      IconButton(  // disabled, decorative — actual taps go через outer GestureDetector
        icon: Icon(state.sortMode.icon, size: 20),
        onPressed: null,
        ...
      ),
      if (_isSortNonDefault(state))
        const Positioned(
          right: 6, top: 6,
          child: Icon(Icons.circle, size: 8, color: Colors.amber),
        ),
    ],
  ),
)

bool _isSortNonDefault(HomeState s) =>
    !s.pinDirect || !s.pinAuto || !s.resortOnManualPing;

void _showSortOptionsMenu(BuildContext ctx) async {
  // PopupMenuButton.showButtonMenu не имеет публичного API без RenderBox —
  // используем showMenu(position: ...) с RelativeRect от sort button.
  final box = _sortButtonKey.currentContext?.findRenderObject() as RenderBox?;
  if (box == null) return;
  final pos = box.localToGlobal(Offset.zero);
  await showMenu<_SortMenuAction>(
    context: ctx,
    position: RelativeRect.fromLTRB(pos.dx, pos.dy + box.size.height, ...),
    items: [
      CheckedPopupMenuItem(value: _SortMenuAction.pinDirect,
        checked: state.pinDirect, child: Text('Pin DIRECT to top')),
      CheckedPopupMenuItem(value: _SortMenuAction.pinAuto,
        checked: state.pinAuto, child: Text('Pin AUTO to top')),
      CheckedPopupMenuItem(value: _SortMenuAction.resortPing,
        checked: state.resortOnManualPing,
        child: Text('Re-sort on manual ping')),
    ],
  );
  // обработка selected → controller.setXxx(!current)
}
```

### Visual mock

```
Nodes (12)                            [↕•] [☷]
                                          ↑
                                yellow dot если non-default
```

Long-press открывает menu:

```
┌────────────────────────────────────┐
│ ☑ Pin DIRECT to top                │
│ ☑ Pin AUTO to top                  │
│ ☐ Re-sort on manual ping           │
└────────────────────────────────────┘
```

---

## Edge cases

| Сценарий | Поведение |
|---|---|
| pinDirect OFF, sort = ping | direct-out сортируется по latency как обычная нода |
| pinDirect ON, sort = default | direct-out **не** пиннится — defaultOrder = `return nodes` без spec.обработки. ⚠ Спорно. **Decision: pin applies только для non-default mode.** Default = «как пришло из proxiesJson», pin — это override sort'а |
| resort OFF + group switch | bump pingBatchGen → cache invalid → новый sort. OK. |
| resort OFF + batch complete | bump → cache invalid → re-sort. OK. |
| resort OFF + добавилась нода (subscription update) | `nodes.length` change → cache invalid → re-sort. OK. |
| resort OFF + нода удалена | `every(contains)` sanity check → cache invalid → re-sort. OK. |
| Толк в popup item на disabled toggle | toggle применяется immediate, popup закрывается. Standard PopupMenu behavior. |

---

## Файлы

- `app/lib/models/home_state.dart` — 4 поля + copyWith.
- `app/lib/controllers/home_controller.dart` — setters + bump в 4 точках.
- `app/lib/screens/home_screen.dart` — GestureDetector wrap, popup menu, yellow dot, `_viewSortedNodes` cache.
- `app/test/models/home_state_test.dart` — pin OFF tests, manual mode (через §071), pingBatchGen cache test.
- `docs/spec/features/070 sort-options/spec.md` (этот файл).
- `CHANGELOG.md` — entry.

## Locked decisions

1. **Toggles per-session in-memory.** Persist = миграция storage, отдельный scope.
2. **HomeState owns sort state.** Single source of truth — НЕ controller-side.
3. **`pingBatchGen` — passive counter.** Не несёт semantic «сортируй сейчас», только маркер для cache invalidation.
4. **Pin не работает в `defaultOrder` mode.** Default = pristine config order, pin это override для sorted modes.
5. **PopupMenu (не bottom-sheet)** — 3 чекбокса, стандарт Material.
6. **Yellow dot indicator** на sort button когда хоть одна опция non-default.
7. **`resortOnManualPing` независим от sortMode.** Применяется ко всем modes (даже в `nameAsc` теоретически lastDelay в key — фактически не используется, но cache одинаков).

## Тесты

- `pinDirect=false, sortMode=latencyAsc, nodes=[direct-out, x, y]` → direct-out НЕ первый, сортируется по lastDelay
- `pinAuto=false, sortMode=nameAsc` → ✨auto сортируется по имени
- `pingBatchGen=0 → 1` при том же `lastDelay` → cache key change (через _viewSortedNodes если был мок)
- `resortOnManualPing=false`, cache hit → возвращает same instance
- `nodes` lost one tag → sanity check → cache miss

## Acceptance criteria

- [ ] Long-press на sort button открывает popup с 3 чекбоксами в текущих значениях.
- [ ] Tap чекбокса меняет toggle, popup закрывается, sort/UI обновляется immediate.
- [ ] Все 3 toggle defaults = ON → существующее поведение бит-в-бит.
- [ ] Pin DIRECT OFF → `direct-out` в `latencyAsc` сортируется по latency.
- [ ] Pin AUTO OFF → `✨auto` в `nameAsc` сортируется по имени.
- [ ] Resort OFF → manual ping (одна нода) не меняет порядок ряда; mass ping → один re-sort после finish.
- [ ] Yellow dot виден на sort button когда хоть одна опция non-default.
- [ ] Existing `cycleSortMode` (короткий tap) работает как раньше.
