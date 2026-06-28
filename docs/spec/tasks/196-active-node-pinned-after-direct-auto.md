# §196 — Активная нода вверху после direct/auto при любой сортировке

> **СТАТУС: РЕАЛИЗОВАНО (28.06.2026).** Ветка `feat/configurable-channels-125`.

## Контекст

Pinned-секция списка нод на главной ([`HomeState._computeSortedNodes`](../../../app/lib/models/home_state.dart))
держит сверху служебные ноды: `direct` + `urltest`-двойники (§070 тоглы
pinDirect/pinAuto; §125 — пин по типу из конфига). Остальные ноды сортируются
выбранным режимом (latency/name/manual/default).

Активная нода группы (`activeInGroup` — текущий выбранный outbound) при
non-default сортировке могла оказаться где угодно в списке (по latency/имени) —
юзер терял её из виду.

## Цель

Активную ноду закреплять **сразу после direct/auto**, при **ЛЮБОЙ** сортировке
(не за тоглом — всегда). Порядок pinned-секции:

```
direct  →  urltest-двойники (config-order)  →  активная нода  →  [rest по сортировке]
```

Условия пина активной:
- `activeInGroup != null && непустая`;
- присутствует в `nodes` (иначе игнор);
- **НЕ** уже в pinned (если активная — сам direct/auto-двойник, не дублируем).

## Реализация

`HomeState`:
- `_computePinned()` (вынесен из `_computeSortedNodes`) — собирает pinned-секцию:
  direct → urltest → активная. Late-поле `_pinnedTags`.
- `pinnedNodeCount` геттер = `_pinnedTags.length`. **Единый источник истины**
  для node_list (раньше pinnedCount пересчитывался по фикс-тегам `direct-out`/
  `✨auto` — расходилось с §125 auto-двойниками И не знало про активную).
- `_computeSortedNodes` использует `_pinnedTags` + rest.

`node_list.dart` (`_buildReorderableNodeList`):
- pinnedCount считается как длина общего префикса `displayList` и
  `sortedNodes.take(pinnedNodeCount)` — robust против фильтра §048 (если pinned
  затолкан в nonMatching, префикс короче → меньше non-draggable). Убран хардкод
  `== 'direct-out'`/`== kAutoOutboundTag`.

## Тесты

`home_state_sort_test.dart` — группа §196: активная после direct/auto при
latency/name/default; не-дублирование если активная = direct/auto; нет активной
→ старое поведение; `pinnedNodeCount` = direct+auto+активная; активная ∉ nodes →
игнор. Сьют зелёный.

## Связанные

- [§070 node-sort-pin](../features/...) — тоглы pinDirect/pinAuto.
- [§071 manual-reorder](../features/...) — pinnedCount → non-draggable секция.
- [§125 configurable-channels](../features/125%20configurable-channels/spec.md) —
  пин по типу из конфига (auto-двойники vpn-N-auto).
