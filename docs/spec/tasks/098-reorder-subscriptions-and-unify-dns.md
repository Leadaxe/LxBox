# 098 — Drag-reorder подписок + унификация reorder DNS-правил

| Поле | Значение |
|------|----------|
| Тип | UI consistency + wiring (без новой логики) |
| Триггер | Юзер: «как правила в рулах можно таскать — сделай так чтобы порядок подписок можно было менять, и так же оформи изменение порядка в правилах DNS, а то там по-другому» |
| Эталон | routing rules (`custom_rule_tile` + `RoutingRulesTab`) — левый вертикальный grab-strip |

## Проблема

- **Подписки** (`subscriptions_screen`) — `ListView.separated`, переставлять
  нельзя. При этом контроллер УЖЕ умеет: `SubscriptionController.moveEntry(from,
  to)` (reorder `_entries` + `_persist` + notify) — но в UI не подключён (звался
  только из Debug API).
- **DNS rules** и **routing rules** — оба `ReorderableListView`, но drag-аффорданс
  «по-разному»: routing = левый вертикальный **grab-strip** (`drag_indicator` в
  тонированной полосе на всю высоту), DNS = мелкая inline-иконка `drag_handle`
  рядом со Switch в `Card/ListTile`.

## Решение — единый grab-strip

Новый widget **`lib/widgets/reorder_grab_strip.dart`** (`ReorderGrabStrip(index)`)
— извлечён из routing-строки (вертикальная полоса 18px, `surfaceContainerHighest`,
`drag_indicator`, обёрнут в `ReorderableDragStartListener`). Один источник правды
для всех трёх списков.

### Изменения

| Файл | Что |
|------|-----|
| `widgets/reorder_grab_strip.dart` | NEW — общий grab-strip |
| `routing_screen/widgets/custom_rule_tile.dart` | inline grab-strip → `ReorderGrabStrip` (визуально идентично, DRY) |
| `dns_settings_screen/widgets/dns_rule_tile.dart` | убрана inline `drag_handle`; `Card/ListTile` обёрнут в `IntrinsicHeight > Row > [ReorderGrabStrip, Expanded(Card)]`; leading = только Switch |
| `subscriptions_screen/widgets/subscription_entry_tile.dart` | +`dragIndex`; `ListTile` обёрнут в `IntrinsicHeight > Row > [ReorderGrabStrip, Expanded(Column[tile, Divider])]` (divider раньше был `separatorBuilder`) |
| `subscriptions_screen.dart` | `_buildList`: `ListView.separated` → `ReorderableListView.builder` (`buildDefaultDragHandles:false`), `onReorder` → `moveEntry` (с `newIndex-=1` при move вниз), `key: ValueKey(entry.id)` |
| `home/widgets/node_list.dart` | §071 manual-сортировка: в режиме `NodeSortMode.manual` non-pinned ряд = `IntrinsicHeight > Row [ReorderGrabStrip, Expanded(row)]` (видимая полоса как routing, immediate-drag); в остальных режимах — прежний transparent overlay + long-press (drag → switch в manual). Pinned (direct/auto) — без полосы. |

## Поведение

- Reorder подписок мгновенно персистится (`moveEntry → _persist`), как `toggleAt`.
  **Конфиг не регенерится** автоматически (тот же паттерн, что toggle — порядок
  подхватится при следующем generate; orden entries → порядок нод в build'е).
- Pull-to-refresh сохранён: `ReorderableListView` скроллируем,
  `AlwaysScrollableScrollPhysics` + `RefreshIndicator` как было.
- Drag только за grab-strip (`buildDefaultDragHandles:false`) — long-press по
  телу строки остаётся контекстным меню.

## Тесты / проверка

`moveEntry` уже покрыт через Debug API path. UI-reorder — ручная device-проверка
(подписки таскаются, DNS-правила выглядят как routing). analyze clean.

## Статус — DONE ✅ (device-verify на юзере)
