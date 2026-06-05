# 071 — Manual node reorder via drag

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-06-05 |
| Зависимости | §070 (`HomeState` уже имеет pin toggles + `pingBatchGen`), `NodeSortMode` enum |
| Связанные | §048 (filter — non-matching rows тоже draggable, dimming через Opacity сохраняется) |
| Триггер | Юзер хочет ручной порядок нод вне рамок Default/Ping/A-Z. Drag-handle на ряду стандарт Android. |

## Цель

Добавить 4-й sort mode `manual` который активируется **только** через drag, не через cycle / menu. На левом краю каждого ряда — 10px невидимая grab-strip; long-press + drag начинает reorder.

Sort-кнопка показывает `⠿ Icons.drag_indicator` когда mode == manual.

Exit из manual: tap по sort button → cycle переходит в `default`, `manualOrder` **сбрасывается**. Drag снова → re-enter manual с fresh order.

## Не в скопе

- Persistence через рестарт — manualOrder per-session in-memory (consistency с §070 toggles).
- Drag handle visual indicator поверх ряда — strip полностью прозрачен.
- Drag для pinned (direct / auto) — pinned секция всегда non-draggable.
- Backup format — manualOrder не сохраняется.

---

## Текущее состояние

```
NodeSortMode { defaultOrder, latencyAsc, nameAsc }
ListView.builder в _buildNodeList — нет drag вообще.
```

---

## Целевое состояние

### NodeSortMode enum — +1 значение

```dart
enum NodeSortMode {
  defaultOrder('Default', Icons.swap_vert),
  latencyAsc('Ping', Icons.signal_cellular_alt),
  nameAsc('A–Z', Icons.sort_by_alpha),
  manual('Custom', Icons.drag_indicator);  // ← новый

  NodeSortMode get next => switch (this) {
    NodeSortMode.defaultOrder => NodeSortMode.latencyAsc,
    NodeSortMode.latencyAsc => NodeSortMode.nameAsc,
    NodeSortMode.nameAsc => NodeSortMode.defaultOrder,
    NodeSortMode.manual => NodeSortMode.defaultOrder,
    // manual → defaultOrder, обходит cycle (single exit).
  };
}
```

`next` больше не построен через `values[(index + 1) % length]` — manual вне cycle.

### HomeState — `manualOrder` поле

```dart
class HomeState {
  // ...existing (включая §070 поля)...
  final List<String> manualOrder;  // default const [] — пусто или установлено через commitManualReorder
}
```

`_computeSortedNodes`:

```dart
List<String> _computeSortedNodes() {
  if (sortMode == NodeSortMode.defaultOrder) return nodes;

  final pinnedOrder = <String>[
    if (pinDirect) 'direct-out',
    if (pinAuto) kAutoOutboundTag,
  ];
  final pinned = pinnedOrder.where(nodes.contains).toList();
  final rest = nodes.where((n) => !pinnedOrder.contains(n)).toList();

  switch (sortMode) {
    case NodeSortMode.latencyAsc:
      rest.sort(_compareLatency);
    case NodeSortMode.nameAsc:
      rest.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    case NodeSortMode.manual:
      // manualOrder filtered к present nodes + новые ноды (не в manualOrder) в конец.
      final restSet = rest.toSet();
      final ordered = <String>[
        ...manualOrder.where(restSet.contains),  // saved order, существующие
        ...rest.where((n) => !manualOrder.contains(n)),  // новые → конец
      ];
      return [...pinned, ...ordered];
    case NodeSortMode.defaultOrder:
      break;
  }
  return [...pinned, ...rest];
}
```

### HomeController

```dart
/// Commit reorder + переключить в manual mode. Вызывается из ReorderableListView
/// onReorder callback. Принимает новый порядок (полный list non-pinned tags).
void commitManualReorder(List<String> newOrder) {
  _emit(_state.copyWith(
    sortMode: NodeSortMode.manual,
    manualOrder: List<String>.unmodifiable(newOrder),
  ));
}

/// cycleSortMode из manual → defaultOrder сбрасывает manualOrder.
void cycleSortMode() {
  final next = _state.sortMode.next;
  _emit(_state.copyWith(
    sortMode: next,
    // exit из manual → clear manualOrder
    manualOrder: next == NodeSortMode.defaultOrder &&
                 _state.sortMode == NodeSortMode.manual
        ? const <String>[]
        : _state.manualOrder,
  ));
}
```

### UI — `ReorderableListView` + 10px grab strip

`_buildNodeList`:

```dart
ReorderableListView.builder(
  buildDefaultDragHandles: false,  // мы провайдим свои через strip
  itemCount: displayList.length,
  onReorder: (oldIndex, newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final pinnedCount = (state.pinDirect && nodes.contains('direct-out') ? 1 : 0) +
                        (state.pinAuto && nodes.contains(kAutoOutboundTag) ? 1 : 0);
    // Не давать дропнуть в pinned слот:
    if (newIndex < pinnedCount) newIndex = pinnedCount;
    if (oldIndex < pinnedCount) return;  // pinned — не двигаются
    // Применить move к non-pinned части:
    final restOnly = displayList.skip(pinnedCount).toList();
    final restOld = oldIndex - pinnedCount;
    final restNew = newIndex - pinnedCount;
    final moved = restOnly.removeAt(restOld);
    restOnly.insert(restNew, moved);
    _controller.commitManualReorder(restOnly);
  },
  itemBuilder: (ctx, i) {
    final tag = displayList[i];
    final isPinned = i < pinnedCount;
    final row = NodeRow(item: viewItemFor(tag), ...);
    if (isPinned) {
      return KeyedSubtree(key: ValueKey('node-$tag'), child: row);
    }
    return KeyedSubtree(
      key: ValueKey('node-$tag'),
      child: LayoutBuilder(
        builder: (ctx, c) => Stack(
          children: [
            row,  // text/icons не двигаются
            Positioned(
              left: 0, top: 0, bottom: 0,
              width: c.maxWidth * 0.05,  // 5% от ширины row
              child: ReorderableDragStartListener(
                index: i,
                child: const SizedBox.expand(),  // transparent
              ),
            ),
          ],
        ),
      ),
    );
  },
)
```

Каждому item обязателен `Key` — ReorderableListView требует.

### Visual mock

```
[Default mode]   sort button = ↕
Nodes (12)                       [↕] [☷]

┌──────────────────────────────────────────────────┐
│┃ direct-out                       (pinned)       │  ← non-draggable
│┃ ✨auto                            (pinned)       │  ← non-draggable
│┃ 🇷🇺 Moscow #1            42ms ⚡  │  ← 10px strip = grab
│┃ 🇷🇺 Moscow #2            68ms ⚡  │
│┃ 🇺🇸 NY #1               120ms ⚡  │
└──────────────────────────────────────────────────┘
 ↑
 invisible strip (transparent)

User long-press + drag node #2 → sort mode auto-switches to manual,
manualOrder сохраняется в HomeState.

[Manual mode]    sort button = ⠿
Nodes (12)                       [⠿] [☷]

(порядок остался какой выставил юзер)

User taps sort → exit к default, manualOrder сброшен.
User starts drag again → manual mode re-enter, fresh manualOrder.
```

---

## Edge cases

| Сценарий | Поведение |
|---|---|
| Drag в default mode | onReorder → commitManualReorder → mode становится manual + applies reorder одной операцией |
| Drag в ping mode | то же — switch to manual + apply |
| Pinned ряд (direct-out) — попытка drag | `oldIndex < pinnedCount` → ignored. Drag-strip всё равно есть, но handler делает return. **TODO: лучше не рендерить strip для pinned**, чтоб не было визуального «нажал, ничего» |
| Drop в pinned зону (на самый верх) | `newIndex < pinnedCount → clamp to pinnedCount`. Node landings just under pinned. |
| Новая нода добавлена через subscription update — в manual mode | `_computeSortedNodes` берёт `manualOrder.where(present)` потом `rest.where(!manualOrder.contains)` → новые в конце. |
| Нода удалена из subscription | manualOrder автоматически фильтруется (.where(present)). Если все удалены → manualOrder effectively empty, но sortMode остаётся manual. Tap sort → exit. |
| Toggle pinDirect ON во время manual | direct-out перемещается в pinned section, остальной manualOrder не трогается. |
| Mass URLtest finishes в manual mode | pingBatchGen bump, но в `manual` sortMode latency не используется → порядок не меняется. Cache miss = OK, переехать в тот же порядок. |
| Filter (§048) non-matching dimmed | rows всё ещё draggable, dim через Opacity сохраняется поверх Stack. |

## Файлы

- `app/lib/models/home_state.dart` — `NodeSortMode.manual` + `manualOrder` поле + update `next` + update `_computeSortedNodes`.
- `app/lib/controllers/home_controller.dart` — `commitManualReorder`, update `cycleSortMode` для exit-from-manual.
- `app/lib/screens/home_screen.dart` — `ListView → ReorderableListView`, grab strip, KeyedSubtree wrap, onReorder handler.
- `app/test/models/home_state_test.dart` — manual mode tests: order applied, новые ноды в конец, exit clears manualOrder.
- `docs/spec/features/071 manual-node-reorder/spec.md` (этот файл).
- `CHANGELOG.md` — entry.

## Locked decisions

1. **Manual mode не доступен через cycleSortMode tap.** Cycle: default → ping → A-Z → default. Manual только через drag.
2. **Exit = cycleSortMode из manual → defaultOrder, manualOrder cleared.**
3. **manualOrder per-session in-memory.** Без storage.
4. **Новые ноды → конец manualOrder.**
5. **Pinned (direct/auto) — non-draggable.** Pin toggle из §070 применяется в manual mode тоже.
6. **8% от ширины row, transparent strip слева** — grab handle. Текст и иконки внутри NodeRow не сдвигаются (Stack + Positioned overlay поверх). На типичных экранах ~28-32px; на foldable/tablet больше.
7. **`buildDefaultDragHandles: false`** — ReorderableListView не показывает свои default handles, только наш strip.
8. **Onbording / hint** — никакого. Discoverability через accidental long-press на левом крае. Если будет слабая — добавим tooltip позже.

## Acceptance criteria

- [ ] Sort button в `manual` mode показывает `⠿ Icons.drag_indicator`.
- [ ] Cycle (короткий tap) НЕ заходит в manual. С manual → default, manualOrder cleared.
- [ ] Drag из left 10px strip переключает в manual mode + сохраняет порядок.
- [ ] Текст и иконки внутри ряда не сдвигаются при появлении/отсутствии strip.
- [ ] Pinned direct/auto — non-draggable; drop в pinned зону клампится под pinned.
- [ ] Subscription update — новые ноды появляются в конце manual order.
- [ ] Subscription delete — нода исчезает из manual order автоматически.
- [ ] Toggle pinDirect/Auto во время manual — pinned section обновляется, manual order intact.

## Open Qs (для решения после первого APK)

- ~~Strip width 10px достаточно?~~ → 8% от width (LayoutBuilder), без clamp.
- Нужен ли visual indicator (тонкая полоска / эмодзи) что юзер может тащить? Сейчас полностью прозрачно — discoverability низкая.
- Haptic feedback при drag start?
