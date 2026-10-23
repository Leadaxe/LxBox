# 676 — «Default traffic» (`route.final`) переезжает в хвост вкладки Rules

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата начала | 2026-10-23 |
| Дата конца | — |
| Коммиты | см. `git log --grep 676` |
| Связанные спеки | [features/026-DIRECTIONS/FUNCTIONS/direction-model.md](../features/026-DIRECTIONS/FUNCTIONS/direction-model.md) (строка «Default traffic»); [features/004-ROUTING_RULES](../features/004-ROUTING_RULES/FEATURE.md) (если такая фича есть — исполнителю найти фичу вкладки Rules по `docs/spec/features/README.md`) |

## Проблема

Дропдаун «Default traffic» (`route.final`) стоит в хвосте вкладки Directions
после разделителя (`app/lib/screens/routing_screen/widgets/routing_tabs.dart:52-54`,
тайл `widgets/route_final_tile.dart`). По смыслу `route.final` — «куда идёт
трафик, который не поймало ни одно правило», то есть последнее неявное
правило маршрутизации, а не свойство направлений: его значениями бывают
`direct` и `block`, которые направлениями не являются. sing-box держит
`route.final` рядом с `route.rules`, Clash показывает `MATCH` последней
строкой правил.

Решение владельца 23.10.2026: перенести на вкладку Rules, в самый низ.
Не дублировать: два контрола на одну настройку на соседних вкладках
порождают вопрос «какой главный».

## Решение

- `RoutingRulesTab` (`routing_tabs.dart`, `ListView` с
  `ReorderableListView.builder` внутри и кнопкой добавления) получает тайл
  `routeFinalTile` после кнопки добавления: `Divider` + тайл, как сейчас на
  Directions. Тайл **не** участвует в перетаскивании правил и не нумеруется
  как правило.
- `RoutingDirectionsTab` тайл и параметр `routeFinalTile` теряет; разделитель
  перед ним — тоже.
- Подпись тайла: «Default traffic (no rule matched)». Сам пикер значений
  (`direct` · включённые направления · `block`, `routing_screen_helpers.dart`)
  и запись `route.final` не меняются.
- Строка-подсказка на вкладке Directions («Enabled directions appear in the
  selector…») не трогается.
- Debug API, automation, хранилище, сборка — без изменений.
- Тесты, которые ищут «Default traffic» на вкладке Directions, перевести на
  Rules (grep `Default traffic` в `app/test`).

## Проверка

- Widget: на вкладке Rules последним элементом стоит тайл «Default traffic
  (no rule matched)», выбор значения записывает `route.final` как раньше; на
  вкладке Directions тайла нет.
- Widget: перетаскивание правил не затрагивает тайл (он вне
  `ReorderableListView`).

## Docs to update

- `direction-model.md` строка «Default traffic» — где живёт контрол;
  фича вкладки Rules — пункт про `route.final` в хвосте;
  `features/026-DIRECTIONS/FEATURE.md`, если там упомянуто место тайла.
- CHANGELOG `[Unreleased]`.
