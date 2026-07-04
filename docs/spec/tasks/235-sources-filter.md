# §235 — Фильтр нод: «Subscribes» → «Sources» (подписки + папки)

> СТАТУС: реализовано (04.07.2026). Продолжение §234 (папки серверов).

## Что

Таб фильтра нод на главном экране (§048/§091/§095) фильтровал только по
подпискам. Теперь **источник** = подписка ИЛИ папка (§234):

1. Таб «Subscribes» переименован в **«Sources»** (hint «No subscriptions» →
   «No sources»).
2. Чип источника показывается и для папки: `enabled` + непустой `tag_prefix`
   + ≥1 нода (тот же §091-критерий, что у подписки).
3. Принадлежность ноды источнику — прежний prefix-механизм §091
   (`tag.startsWith('$prefix ')`), теперь для обоих типов. Одиночный
   `UserServer` по-прежнему НЕ участвует (§091: UI не даёт ему префикс).

## Решения

- `subscriptionsOfTag` → **`sourcesOfTag`**, файл `subscription_lookup.dart` →
  `source_lookup.dart`; `subOptions` → **`sourceOptions`** по цепочке
  presenter → NodeListData → node_list → filter_panel.
- Внутренние поля модели фильтра (`NodeFilter.subscriptions`,
  `enabledSubscriptions`, `subscriptionsInvert` и парные в
  `channel_filters.dart`) НЕ переименованы — семантика «выбранные id
  источников» зафиксирована комментарием; рипл в персист каналов и тесты
  того не стоит.

## Файлы

| Файл | Изменение |
|---|---|
| `screens/home/source_lookup.dart` | бывш. subscription_lookup; папки участвуют |
| `screens/home/node_list_presenter.dart` | `sourceOptions` собирает и папки |
| `screens/home/widgets/filter_panel.dart` | таб «Sources», hint |
| `screens/home/widgets/node_list.dart` | проброс `sourceOptions` |
| `test/screens/home/source_lookup_test.dart` | + folder-кейсы |

## Связанные

- §234 server-folders (источник термина «folder»); §091 prefix-модель;
  §048 home-node-filters.
