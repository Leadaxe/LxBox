# 676 — «Default traffic» (`route.final`) переезжает в хвост вкладки Rules

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата начала | 2026-10-23 |
| Дата конца | 2026-10-23 |
| Коммиты | см. `git log --grep 676` |
| Связанные спеки | [features/026-DIRECTIONS/FUNCTIONS/direction-model.md](../features/026-DIRECTIONS/FUNCTIONS/direction-model.md) (строка «Default traffic»); [features/004-ROUTING/FUNCTIONS/rule-order.md](../features/004-ROUTING/FUNCTIONS/rule-order.md) (вкладка Rules) |

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

### Сделано

- `app/lib/screens/routing_screen/widgets/routing_tabs.dart:94-153` —
  `RoutingRulesTab` получил параметр `routeFinalTile`; в `ListView` после
  кнопки «Add rule» — `Divider(height: 24)` + тайл (стр. 148-149), вне
  `ReorderableListView.builder`. `RoutingDirectionsTab` параметр и
  разделитель потерял (стр. 8-53).
- `app/lib/screens/routing_screen.dart:409-436` — `_buildRouteFinalTile()`
  передаётся в `RoutingRulesTab` вместо `RoutingDirectionsTab`; сам билдер
  (`:1029`) и запись `route.final` не тронуты.
- `app/lib/screens/routing_screen/widgets/route_final_tile.dart:25` — подпись
  «Default traffic (no rule matched)»; пикер не менялся.
- l10n: ключ `"Default traffic"` переименован в
  `"Default traffic (no rule matched)"` в `app/assets/l10n/ru/ui.json` и
  `app/assets/l10n/zh/ui.json` (старый ключ в коде больше не встречается).
- Тестов, искавших «Default traffic» на Directions, не было (grep по
  `app/test` пуст) — переводить нечего.

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

### Результат проверки (2026-10-23)

- `app/test/screens/route_final_on_rules_tab_test.dart` (новый, 3 теста) —
  All tests passed:
  - Rules: тайл последний ребёнок `ListView`, ниже «Add rule», не потомок
    `ReorderableListView`; выбор `block` в дропдауне отдаёт `block` в
    `onChanged` (тот же колбэк, что пишет `route.final`).
  - Rules: перетаскивание правила за ручку вызывает `onReorder` один раз,
    тайл остаётся на месте последним.
  - Directions: тайла и текста «Default traffic» нет.
- `ui_check --strict` чистый; `flutter analyze` чистый.
- На устройстве не проверено.
