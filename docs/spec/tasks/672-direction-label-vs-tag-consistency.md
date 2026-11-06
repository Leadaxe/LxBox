# 672 — Направления: label вместо tag везде, где есть маппинг

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата начала | 2026-10-23 |
| Дата конца | 2026-10-23 |
| Коммиты | см. `git log --grep 672` |
| Связанные спеки | [features/026-DIRECTIONS](../features/026-DIRECTIONS/FEATURE.md) P2 (tag неизменяем), [FUNCTIONS/direction-model.md](../features/026-DIRECTIONS/FUNCTIONS/direction-model.md):60 |

## Проблема

GitHub issue #171 п.19: «Renaming direction's name doesn't rename its tag and
in the ui its using both the new name and the old tag interchangeably — it's
very confusing».

Tag направления неизменяем по спеке (P2), меняется только Title (label). Это
не меняем. Дефект в другом: маппинг tag→label в коде есть
(`Direction.displayLabel` — `models/direction.dart:466`;
`HomeState.groupLabels`/`groupLabelOf` — `models/home_state.dart:168`;
`detourDirectionDisplay` — `widgets/detour_target_picker.dart:44`), но
применён не везде, поэтому один и тот же объект на соседних элементах
подписан по-разному.

## Диагностика

Где показан сырой tag при наличии маппинга под рукой:

| Место | file:line | Источник |
|---|---|---|
| Шторка: заголовок `[final = …]` и строка `<group>: <node>` | `controllers/home_controller.dart:924,934` | `route.final`/`selectedGroup`; `_directionLabels` лежит в том же классе и не использован |
| Строка узла на home, когда член — другое направление (`vpn-2`) | `widgets/node_row.dart:613` (через `node_list.dart`) | `item.tag`, для selector подмены нет |
| Редактор: заголовок «Edit direction · %s» и строка под ним | `direction_edit_screen.dart:402,438` | storage |
| Редактор: кандидаты-папки | `direction_edit_screen.dart:289` | storage |
| Stats/Live: строки Chain и Detour | `stats_screen/routing_section.dart:50,54`, `vpn/cc_channel.dart:1268-1281` | теги от ядра; `groupLabels` не проброшен |

Где tag показан **намеренно** и остаётся: позиции цепочки (`chain_edit_screen.dart:521,538`,
комментарий «ТОЛЬКО тег»), подзаголовок плитки Routing (`routing_group_tile.dart:41-43` — label
заголовком, tag ниже; это и есть целевой образец), Debug API/automation.

## Решение

Правило: везде, где направление показывается пользователю, первичная строка —
label (`displayLabel`/`groupLabelOf`), tag — вторичная строка или в скобках,
как на плитке Routing. Tag не прячется полностью: он нужен для сверки с Debug
API и правилами.

- Шторка: `_directionLabels[group] ?? group` в обоих местах.
- Home, строка члена-направления: `groupLabelOf(tag)` перед `NodeRow`
  (в `node_list.dart`), tag — в подзаголовок, если его там нет.
- Редактор: заголовок — label, tag — мелкой строкой ниже (там, где сейчас
  обе строки tag).
- Кандидаты-папки в редакторе: label + tag подзаголовком, как у «Other
  directions» (`direction_edit_screen.dart:264-265`).
- Stats/Live: пробросить карту `groupLabels` (или `getDirections()`) в
  `foldSelectorPairs` и формирование строк Chain/Detour; формат
  «label (tag)». Модель соединения в `cc_channel` storage не знает — карту
  передавать снаружи, не тянуть storage в канал.
- Позиции цепочки — не трогать.

### Сделано

- Шторка: строки собирает чистая `HomeController.notificationLines`
  (`controllers/home_controller.dart:937`), `_pushNotificationLabels` (`:921`)
  только отправляет; `directionLabels[tag] ?? tag` у селектора и у `route.final`.
- Home: `node_list.dart:594-595` берёт `state.groupLabels[tag]`; label уходит в
  новое поле `NodeViewItem.displayLabel` (`widgets/node_view_item.dart`), `NodeRow`
  рисует его заголовком (`widgets/node_row.dart:615`); tag — первым звеном
  подзаголовка (`protocolLabel`), у селектора без протокола — им одним.
- Редактор: заголовок «Edit direction · %s» берёт `c.displayLabel`
  (`direction_edit_screen.dart:403`); строка tag под ним уже была.
- Кандидаты-папки: не тронуты. Это свёртки источников (`FoldCandidate` =
  `{tag, source}`, `direction_edit_screen.dart:967`), не Направления: у группы
  свёртки нет label отдельно от tag, имя группы и есть tag, а подзаголовок уже
  несёт имя источника. Маппинга tag→label для них нет.
- Stats/Live: `directionTagDisplay(tag, labels)` → `label (tag)`
  (`services/selector_info.dart:112`); `foldSelectorPairs(chain, labels:)` подписывает
  элементы, признак селектора по сырому тегу. Карта — параметром (`labels`) в
  `CcConnection.routingLineOf` (`vpn/cc_channel.dart:1253`), зеркальном
  `TrafficEvent.routingLineOf` (`services/traffic_profiler/models.dart`) и
  `routingRows` (`stats_screen/routing_section.dart:50-59`); storage в канал не
  попал. Источник карты — `homeController.state.groupLabels`: `stats_screen.dart:291`
  → `ConnectionsView` → `showConnectionDetailSheet`; `live_events_tab.dart:231` →
  `TraceExplorer` → `LiveView`, `showTrafficEventDetailSheet`,
  `showAggregateDetailSheet`. `routingLine` (дамп) зовёт без карты — сырые теги.
- Свёртка выхода с label: `Germany (vpn-1) (node)` — формат «label (tag)» плюс
  скобка выбора §251.
- Позиции цепочки не тронуты. Новых l10n-строк нет.

## Проверка

- Widget/unit: шторка с label «Germany» для `vpn-1` → текст «Germany: node»;
  Stats Chain для `vpn-1` → «Germany (vpn-1)».
- Ручная: переименовать направление → ни на одном экране из таблицы не
  осталось строки, где tag стоит без label.

### Итог проверки

- `test/screens/direction_label_display_test.dart` (7 тестов, All tests passed):
  шторка `vpn-1`+«Germany» → «Germany: node» и `[final = Germany]`; Chain
  `vpn-1` → «Germany (vpn-1)»; Detour со свёрткой; routing-строка Conns ≡ Live с
  картой и сырые теги без неё; `NodeRow` члена-Направления — label заголовком,
  tag в подзаголовке. `flutter analyze` чистый.
- Ручная проверка на устройстве не проводилась.

## Docs to update

- `features/026-DIRECTIONS/FUNCTIONS/direction-model.md` — правило показа.
- CHANGELOG `[Unreleased]`.
