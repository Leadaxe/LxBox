# §377 — «Detour removed» тонет в собственном шуме

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-08-04 |
| Дата завершения | 2026-08-04 |
| Связанные spec'ы | [§172](172-heal-dangling-detour.md) — сам heal-степ; [§376](376-FEEDBACK-kernel-urltest-goroutines-survive-restart.md) — дамп, из которого это вылезло |

## Проблема

§172 деградирует битую detour-ссылку (detour на outbound, которого в конфиге
нет) и пишет об этом warning — по строке **на каждую ноду**. Подписка, где 138
нод ссылаются на один выключенный WARP-пресет, даёт 138 идентичных строк на
сборку.

В дампе пользователя 4PDA (2026-08-04) две пересборки за сессию дали **276 строк
из 305** в debug-логе. Всё, что было в логе до них, вытеснено ротацией: полезных
записей осталось около тридцати. При разборе того дампа пришлось фильтровать
лог `grep -v`, чтобы вообще увидеть последовательность событий.

Строки различались только именем ноды:

```
Detour removed: outbound "🇳🇱 Black - #26" referenced missing "🔥⛈️ WARP (AWG 1.5)" — node works directly.
Detour removed: outbound "🇳🇱 Black - #27" referenced missing "🔥⛈️ WARP (AWG 1.5)" — node works directly.
… ×138
```

Информации в них ровно одна: «этот detour отсутствует». Повторённая 138 раз.

## Решение

Агрегация по отсутствующему target'у — одна строка на target вместо строки на
ноду. Имена нод сохранены частично: первые пять плюс счётчик остатка (по ним
видно, из какой подписки ноды пришли; полный список для этого не нужен).

[`build_config.dart`](../../../app/lib/services/builder/build_config.dart) —
группировка результата `healDanglingDetours` по `h.target` + хелпер
`_detourRemovedLine`. Формы:

| Нод | Строка |
|---|---|
| 1 | `Detour removed: outbound "Node-1" referenced missing "warp gen" — node works directly.` |
| 5 | `Detour removed: 5 outbounds ("Node-1", …, "Node-5") referenced missing "warp gen" — nodes work directly.` |
| 138 | `Detour removed: 138 outbounds ("Node-1", …, "Node-5", and 133 more) referenced missing "warp gen" — nodes work directly.` |

Единственная нода печатается по-старому — без счётчика и без «and 0 more»:
«1 outbound» читается хуже, чем само имя.

Сам `healDanglingDetours` не тронут: он по-прежнему возвращает полный список
снятых detour'ов (`owner → target`), агрегация живёт только на стороне
формирования warning'а. Поведение конфига не меняется — это чисто
диагностический вывод.

## Область эффекта

`emitWarnings` уходит в два места, и оба выигрывают одинаково:
`AppLog.I.warning` (debug-лог, он же дамп) в
[`subscription_controller.dart:1807`](../../../app/lib/controllers/subscription_controller.dart)
и §105-снекбар. Локализация не затрагивается: `emitWarnings` — machine-поверхность
с пиненным английским (контракт [`node_warning.dart`](../../../app/lib/models/node_warning.dart)).

## Проверка

[`test/builder/detour_removed_warning_aggregation_test.dart`](../../../app/test/builder/detour_removed_warning_aggregation_test.dart)
— 4 теста через `buildConfig`: 138 нод → одна строка с пятью именами и
«and 133 more»; ровно 5 нод → все имена без счётчика; одна нода → старая форма
в единственном числе; два разных отсутствующих target'а → две строки.

Прогон вместе с существующими detour-тестами (`detour_append_replace_test.dart`,
`heal_dangling_detours_test.dart`) — 21 тест, все зелёные. Регрессии в §172 нет:
его тест проверяет подстроку `Detour removed`, она на месте.

## Docs to update

- `CHANGELOG.md` — Unreleased, user-visible (лог и снекбар).
- `DIAGNOSTICS.md` — не требует: раздел про чтение дампа не описывал этот
  warning отдельно.
