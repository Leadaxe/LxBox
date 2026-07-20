# §296 — FolderProbeController: сдуть folder_detail (1669 строк)

**Тип:** structural refactor (Шаг 3 фичи [§291](../features/291%20layered-architecture-facades/spec.md)) · **Статус:** spec · **Размер:** M

`folder_detail_screen.dart` (1669 — самый жирный экран) — screen==controller:
§236 bulk-action **логика решений** (`_unreachableIndexes`, `_sortByPing`
rank+remap, «slower than» фильтр) живёт в экране; контроллер отдаёт только
примитивы (`setMembersEnabled`/`removeMembersAt`/`applyMembersOrder`), а экран
сам вычисляет индексы. **11 прямых `SettingsStorage`-вызовов** (probe-пороги /
ping-options не получили дом в контроллере — единственный экран subs-домена,
обходящий `SubscriptionController`). Триплет порогов `250/500/700` скопирован 3×.

## Проблема (нарушение §291)

Subs-домен — эталон (§291): `SubscriptionController` владеет мутациями, Debug+
Automation делегируют. Но folder_detail из него выпадает — probe-решения и
threshold-состояние без владельца, в экране.

## Решение

Вынести §236-логику решений + 11 storage-вызовов в `FolderProbeController` (или
расширить `SubscriptionController` probe-секцией), по образцу того же домена.
Экран становится тонким: рендер + вызовы контроллера. Триплет `250/500/700` → одна
константа. Соответствует §291: домен уже имеет эталон рядом, дотягиваем folder.

## Файлы

- новый `lib/controllers/folder_probe_controller.dart` (или секция в
  `subscription_controller`)
- `lib/screens/folder_detail_screen.dart` (логика → контроллер, 11 storage → 0)
- probe-пороги → одна константа

## Приёмка

- §236 решения (unreachable/sortByPing/slower-than) в контроллере, тестируемы.
- 0 прямых `SettingsStorage` в folder_detail.
- Порог `250/500/700` — одна константа.
- Экран заметно сдут.

## Docs to update

- `docs/ARCHITECTURE.md` — FolderProbeController в карте.
