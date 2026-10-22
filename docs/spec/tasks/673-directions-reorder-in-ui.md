# 673 — Направления: перестановка порядка в UI

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата начала | 2026-10-23 |
| Дата конца | — |
| Коммиты | см. `git log --grep 673` |
| Связанные спеки | [features/026-DIRECTIONS](../features/026-DIRECTIONS/FEATURE.md) «Rules and guarantees»; [FUNCTIONS/direction-model.md](../features/026-DIRECTIONS/FUNCTIONS/direction-model.md):47,86,105 |

## Проблема

GitHub issue #171 п.21: «It's impossible to reorder directions in the
directions list. What if a new direction needs to be visible for the existing
ones?»

Порядок направлений нормативен: «"Other directions" may name only Directions
above» (FEATURE.md, Rules). Единственный способ поменять порядок —
`POST /directions/reorder` в Debug API (`direction-model.md:105`). Список с
семантическим порядком без возможности его менять из приложения — логическая
дыра, не вкус: новое направление создаётся последним и не может быть включено
ни в одно существующее.

## Диагностика

- `ReorderableListView` в проекте уже есть у подписок/источников, звеньев
  цепочки, участников папки, DNS-правил и правил маршрута. На вкладке
  Directions (`routing_screen.dart`) его нет.
- Debug API reorder — «bulk replace of the list, heal-free path, by design»
  (FEATURE.md Rules). Это и есть целевой путь записи для UI.

## Решение

- Вкладка Directions: drag-handle и `onReorder`, запись через тот же метод
  хранилища, что у `POST /directions/reorder` (bulk replace, без heal'ов).
  Никакой второй логики записи.
- `vpn-1` переставлять можно (если Debug API это допускает); иначе — зеркалить
  ограничение Debug API, не придумывать своё.
- Ссылки «Other directions», ставшие «вниз» после перестановки: поведение
  такое же, как после Debug API reorder (heal'а нет). Исполнителю проверить
  в сборщике (`build_config.dart`, сборка `include`), что такая ссылка не
  роняет сборку: если роняет — ограничить перемещение в UI (запретить drop,
  дающий ссылку вниз, с подписью), если даёт предупреждение/пропуск — оставить
  как у Debug API. Результат зафиксировать в спеке.
- Во время перестановки фильтр/сортировка списка (если есть) — как у соседних
  списков (участники папки: при активном фильтре drag отключён).

## Проверка

- Widget: перестановка меняет порядок в storage тем же вызовом, что Debug API;
  после перестановки список и сборка используют новый порядок.
- Unit: сборка с `include` на направление ниже — зафиксированное поведение.

## Docs to update

- `features/026-DIRECTIONS/FEATURE.md` Rules и `direction-model.md:105` —
  reorder доступен из UI, тот же bulk-путь.
- CHANGELOG `[Unreleased]`.
