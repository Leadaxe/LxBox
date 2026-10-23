# 673 — Направления: перестановка порядка в UI с запретными зонами; те же ограничения в Debug API

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата начала | 2026-10-23 |
| Дата конца | 2026-10-23 |
| Коммиты | см. `git log --grep 673` |
| Связанные спеки | [features/026-DIRECTIONS](../features/026-DIRECTIONS/FEATURE.md) «Rules and guarantees», Boundaries; [FUNCTIONS/direction-model.md](../features/026-DIRECTIONS/FUNCTIONS/direction-model.md):47,86,105; [591](591-spec-kit-revision-audit.md) вопрос 79 (решение 29.09.2026 пересмотрено 23.10.2026) |

## Проблема

GitHub issue #171 п.21: «It's impossible to reorder directions in the
directions list. What if a new direction needs to be visible for the existing
ones?»

Порядок направлений нормативен: «"Other directions" may name only Directions
above». Менять порядок можно только через `POST /directions/reorder`, который
ссылки не проверяет: ссылка, ставшая «вниз», молча выпадает из конфига с
предупреждением сборки и возвращается при обратном reorder
(`debug/handlers/directions.dart:186-215`, `build_config.dart:1480-1487`).
Новое направление создаётся последним и не может быть включено ни в одно
существующее без Debug API.

## Решения владельца (23.10.2026)

1. Правило «только выше» **остаётся** как UX-правило: порядок списка задаёт,
   кто кого может включать, циклы исключены по построению, пользователь видит
   допустимые включения без скрытой логики. Ядро этого правила не требует
   (разведка: `manager.go:93-150` форка разрешает зависимости сам, циклы ловит
   `circular outbound dependency`), поэтому обоснование в спеке 026 и в
   комментариях кода меняется с «ядро не примет forward-ref» на
   «UX-правило, принято владельцем».
2. Перестановка в UI разрешена, но **не может нарушить ни одной
   существующей ссылки**: запретные зоны при перетаскивании.
3. **Те же ограничения в Debug API**: reorder и правка include, нарушающие
   правило, отвергаются, а не лечатся.
4. `vpn-1` переставляется как все (закрепление лишило бы его возможности
   включать другие направления).

## Решение

### Р1. Перестановка на вкладке Directions

- `ReorderableListView` с той же полосой-ручкой, что у правил маршрута и
  участников папки; запись порядка через `DirectionMutations.bulkReplace` —
  тот же путь, что у `POST /directions/reorder`. Второй логики записи нет.
- **Запретные зоны** для перетаскиваемого направления X считаются в
  `onReorderStart`:
  - *снизу*: первое (самое верхнее) направление Y, у которого `include`
    содержит X, и всё ниже него — X нельзя опустить ниже Y;
  - *сверху*: последнее (самое нижнее) направление Z из `include` самого X,
    и всё выше него — X нельзя поднять выше Z.
  Остальные строки друг относительно друга не двигаются, поэтому границы
  считаются только для X. Выключенные направления участвуют в графе как
  обычные (ссылка на выключенное хранится и оживает при включении).
- Строки в запретных зонах на время drag подкрашиваются цветом ошибки темы
  (`colorScheme.error` с прозрачностью, по образцу подсветки ошибок на соседних
  экранах; нового стиля не изобретать).
- Сброс в запретную зону в `onReorder` игнорируется (список остаётся как был)
  и показывает `SnackBar`: «Cannot move: "<Y label>" includes "<X label>"» или
  «Cannot move: "<X label>" includes "<Z label>"». `onReorderEnd` снимает
  подсветку.
- Фильтра у списка нет, отключать перетаскивание нечему.

### Р2. Debug API

- `POST /directions/reorder`: если новый порядок ставит хоть одну ссылку
  `include` «вниз» — 409, тело с перечнем нарушенных пар
  `{ "conflicts": [ { "direction": "vpn-2", "includes": "vpn-3" } ] }`,
  хранилище не меняется. Проверка состава тегов остаётся как была.
- `PATCH`/`PUT` направления с `include`, называющим направление не выше по
  списку (или само себя, или несуществующее) — 409 с тем же форматом
  (`conflicts` с причиной `not_above` / `self` / `unknown`). Если такой
  проверки сейчас нет — добавить; если есть частично — довести до правила.
- Сборщик не меняется: его предупреждение остаётся последним гардом для
  данных из старых бэкапов.

### Р3. Правда в спеках и комментариях

- `build_config.dart:1471-1472` и `direction_edit_screen.dart:506-507`:
  заменить «ядро отвергло бы forward-ref» на «UX-правило 026: включать можно
  только направления выше; ядру порядок безразличен (разрешает зависимости
  сам)».
- `features/026-DIRECTIONS/FEATURE.md`: Rules — reorder доступен из UI и
  Debug API, оба отвергают порядок, нарушающий ссылку; Boundaries — строку
  «No UI reordering… not planned (owner decision 2026-09-29)» заменить на
  решение 23.10.2026 со ссылкой на 673; обоснование правила — UX, не ядро.
- `direction-model.md:47,86,105` — соответственно.

### Сделано

- Границы зон — чистая функция `directionMoveBounds` (`app/lib/models/direction.dart:338`):
  конечный индекс X в списке без него (семантика `onReorderItem`), плюс Y (`includedBy`) и
  Z (`includesAbove`) для текста снэкбара. Ссылки, уже стоящие вниз (старый бэкап), зону не
  порождают — иначе текущее место X было бы запретным.
- Таб: `ReorderableListView` с `onReorderStart`/`onReorderEnd`
  (`app/lib/screens/routing_screen/widgets/routing_tabs.dart:51-58`), полоса
  `ReorderGrabStrip` в тайле (`routing_group_tile.dart:59`); тайл обёрнут в прозрачную
  `Material` (`routing_group_tile.dart:63`), иначе подложка подсветки прятала ink ListTile
  (debug-ассерт; касалось и вспышки §258). Индекс drag — `_dragDirectionIndex`
  (`app/lib/screens/routing_screen.dart:140`, `:418`), подсветка — `_inForbiddenZone`
  (`:500`): `colorScheme.error` alpha 0.12 + левая полоса, та же форма, что у вспышки §258.
  Сброс — `_onReorderDirection` (`:520`): вне границ — `SnackBar`
  `Cannot move: "%s" includes "%s"` (ru/zh в `assets/l10n/*/ui.json`), список не меняется;
  иначе `DirectionMutations.bulkReplace`.
- Debug API (`app/lib/services/debug/handlers/directions.dart`): reorder —
  `directionOrderConflicts(next, before: directions)` (`:227`, функция —
  `direction.dart:388`) → 409; новые ссылки вниз отвергаются, стоявшие вниз до перестановки
  (старый бэкап) не мешают — иначе такие данные блокировали бы любой reorder. PATCH (`:147`) и
  POST-создание (`:92`) с `include` — `_requireIncludeAbove` (`:353`) поверх
  `directionIncludeConflicts` (`direction.dart:418`): `not_above` / `self` / `unknown`;
  законны Направления выше и группы свёрток источников (`include` их принимает с задачи 570).
  Проверяется только переданный `include`, PATCH других полей старые ссылки не блокирует.
  `PUT /directions/{tag}` в API нет. 409 — `Conflict(message, conflicts: [...])`
  (`app/lib/services/debug/contract/errors.dart:74-87`), `conflicts` рядом с `error`, как
  `dropped` у `BadRequest`.
- До задачи валидации `include` в Debug API не было: проверялась только форма списка.
- Р3: комментарии `build_config.dart:1455-1475`, `direction_edit_screen.dart:505-508`,
  спеки 026 (FEATURE, direction-model, EN+RU), 027 `write-operations` (строка 409),
  `docs/api/debug-api-reference.md`. Сборщик не менялся.

## Проверка

- Unit: функция границ зон для списка `[A, B(incl A), C, D(incl C), E]`:
  для C — нельзя ниже D; для A — нельзя ниже B; для D — нельзя выше C; для E
  — зон нет.
- Widget: drag в запретную зону не меняет порядок и показывает снэкбар; drag в
  допустимое место записывает порядок через `bulkReplace`.
- Unit (Debug API): reorder с нарушением → 409 и список пар; без нарушения →
  200 и новый порядок; PATCH include «вниз» → 409.

Выполнено:

- `app/test/models/direction_move_bounds_test.dart` — четыре случая из спеки (C, A, D, E;
  C выключено), ссылка вниз из бэкапа без зоны, `directionOrderConflicts`,
  `directionIncludeConflicts`.
- `app/test/screens/routing_directions_reorder_test.dart` — drag «Third» (включает
  «Second») наверх: на время drag подкрашены две строки, после сброса подсветки нет,
  снэкбар `Cannot move: "Third" includes "Second"`, порядок в хранилище прежний; drag
  `vpn-1` вниз пишет `vpn-2,vpn-3,vpn-1`, сборка без предупреждений.
- `app/test/services/debug/directions_handler_test.dart` — reorder со ссылкой вниз → 409,
  `conflicts` = `[{vpn-3, vpn-2, not_above}]`, хранилище не тронуто; допустимый → 200;
  ссылка вниз из бэкапа reorder не блокирует; PATCH include → 409 с `not_above`/`self`/
  `unknown`, не пишется; POST с неизвестным include → 409, не создаётся.
- `app/test/builder/direction_include_below_test.dart` — последний гард сборщика для
  данных старого бэкапа.
- На устройстве не проверено.

## Docs to update

- 026 FEATURE.md (Rules, Boundaries), direction-model.md, 027-DEBUG_API
  (коды ответа reorder/PATCH), `docs/api/debug-api-reference*` если там
  описан reorder.
- CHANGELOG `[Unreleased]`.
