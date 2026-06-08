# 092 — Дописать update-dismiss («Later» в update-snackbar)

| Поле | Значение |
|------|----------|
| Статус | **In progress** |
| Тип | logic-rewrite (§090 **G1**) — завершение half-wired фичи |
| Источник | §089 P6 находка: read-guard `getDismissedUpdateVersion` активен, writer'а в UI нет |
| Тип изменения | **behavior-changing** (новая кнопка + suppress) |

## Проблема

`UpdateChecker.dismissCurrent()` (persist `setDismissedUpdateVersion` + clear
`latest`) **никто не звал** — кнопки в UI не было. При этом read-guard уже
работает в 3 местах (`maybeShowUpdateSnackbar` L92, `UpdateChecker.hydrate`,
`UpdateChecker.maybeCheck`). Итог: «скрыть этот релиз» технически готов, но
недоступен пользователю → snackbar показывает один и тот же релиз каждую сессию.

## Решение (decision: дописать, не выпиливать)

Инфраструктура (storage-ключ + read-guard) уже есть и явно задумана →
**завершить** фичу, а не удалять guard. Добавить вторичную кнопку **«Later»** в
content update-snackbar'а:
- tap → `messenger.hideCurrentSnackBar()` + `UpdateChecker.I.dismissCurrent()`;
- `dismissCurrent` пишет `dismissed_update_version = info.tag` + `latest = null`;
- read-guard'ы дальше не показывают **этот** tag (до следующего релиза с бОльшим
  tag — `isNewer` всё равно сработает на новый).

Primary action «View» (открыть релиз) остаётся `SnackBarAction`'ом. «Later» —
`TextButton` в `content`-Row (Material snackbar держит один `action`-слот).

## Файлы

- `lib/screens/home/home_dialogs.dart::maybeShowUpdateSnackbar` — content →
  `Row[Expanded(text), TextButton('Later')]`, action остаётся «View». Все
  импорты уже есть (`dart:async`, `update_checker`, `settings_storage`).
- `test/services/update_checker_test.dart` — +тест `dismissCurrent` (persist +
  clear) через mocked path_provider (паттерн settings_storage_test).

## Не в скопе

- Изменение частоты/политики проверки апдейтов.
- «Никогда не показывать апдейты» (это отдельный глобальный toggle, не здесь).
