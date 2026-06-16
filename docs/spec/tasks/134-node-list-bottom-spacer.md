# 134 — Node-list: bottom-spacer под прокруткой (одна строка запаса)

| Field | Value |
|------|----------|
| Status | Done |
| Started | 2026-06-16 |
| Trigger | Жалоба клиента (Ilya, OnePlus Open / OxygenOS 16): «Последний сервер уезжает под блок с кнопками». Список нод на центральном экране имел `padding: EdgeInsets.zero` → последний ряд упирался прямо в нижний край / под controls-блок, его было неудобно тапнуть и нельзя «доскроллить с запасом». |
| Related | [home/widgets/node_list.dart](../../../app/lib/screens/home/widgets/node_list.dart) (`HomeNodeList` — центральный список нод); [home_screen.dart](../../../app/lib/screens/home_screen.dart) (Column: `HomeControls` сверху → `HomeNodeList` Expanded до низа); [node_row.dart](../../../app/lib/widgets/node_row.dart) (`NodeRow` height=56) |
| Files touched | `app/lib/screens/home/widgets/node_list.dart` (1 строка) |

## Что сделано

В `ReorderableListView.builder` (`_buildReorderableNodeList`) заменён
`padding: EdgeInsets.zero` на `padding: const EdgeInsets.only(bottom: 56)`.

`56` = высота одного `NodeRow` ([node_row.dart:271](../../../app/lib/widgets/node_row.dart#L271)) →
под последним узлом остаётся запас ровно в одну строку. Последний сервер больше
не липнет к нижнему краю и не «уезжает» под нижний блок управления; список
скроллится с запасом.

## Почему так, а не иначе

- Bottom-padding у самого `ScrollView` (а не `SizedBox`-footer в `itemBuilder`) —
  не ломает `itemCount` / индексацию `onReorder` / `pinnedCount`-логику (§070/§071),
  не добавляет лишний reorderable-элемент, не трогает frozen-sort cache.
- Высота привязана к константе ряда (56), а не к произвольному числу — если
  `NodeRow.height` изменится, спейсер останется «одной строкой» по смыслу
  (значение синхронить вручную — оба в одном PR, см. таску).

## Acceptance

- [x] Последний узел доступен к тапу/драгу, не перекрыт нижним краем.
- [x] `onReorder` / `pinnedCount` / drag-strip (§071/§098) не затронуты —
      изменён только `padding` контейнера скролла.
