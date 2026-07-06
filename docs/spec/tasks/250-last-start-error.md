# §250 — `last_start_error`: диагностика падений старта, развязанная с UI

> **СТАТУС: РЕАЛИЗОВАНО** (06.07.2026). Найдено при диагностике §246-падения
> (Legacy `strategy` + FakeIP): сервис падал с внятной причиной, а
> `/state.last_error` был всегда пуст.

## Проблема

`HomeState.lastError` — поле двойного назначения, и UI побеждает диагностику:

1. При стопе с причиной контроллер пишет
   `lastError = 'Stopped: <errorReason>'` (home_controller
   `_handleStatusEvent`, disconnected-ветка).
2. `home_screen` (§166) в тот же build-кадр показывает ошибку SnackBar'ом и
   немедленно зовёт `clearError()` — чтобы не зажигать верхний баннер.
3. Итог: в `/state` Debug API поле живёт миллисекунды; поймать его
   заполненным снаружи невозможно (проверено поллером 3с × 3мин — 60/60
   пустых сэмплов при воспроизведённом падении). Плюс оптимистичные очистки
   `lastError: ''` на каждом Start/Stop/Reload.

## Решение (согласовано с владельцем)

Развести UI и Debug API. UI-поведение (`lastError` + §166) НЕ трогаем.

Новое **in-memory** поле `HomeState.lastStartError` (+ `lastStartErrorAt`):

| Событие | Поведение |
|---|---|
| stop/revoked с причиной | `lastStartError = reason`, `lastStartErrorAt = now` (та же ветка, что пишет lastError) |
| `clearError()` (§166 UI-consume) | НЕ трогает |
| Оптимистичные `lastError: ''` в start/stop/reload | НЕ трогают |
| Успешный старт (`tunnel → connected`) | очищает (`''`/null) — ЕДИНСТВЕННАЯ очистка |
| Рестарт процесса | пусто (in-memory by design — владелец выбрал не персистить) |

`/state` отдаёт `last_start_error` + `last_start_error_at` (ISO-8601 / null).

## Файлы

| Файл | Изменение |
|---|---|
| `models/home_state.dart` | поля `lastStartError`/`lastStartErrorAt`, copyWith (сентинел `_unset` для nullable timestamp) |
| `controllers/home_controller.dart` | запись в disconnected/revoked-ветке; очистка в connected-ветке; `clearError` не трогает |
| `services/debug/serializers/home_state.dart` | `last_start_error`, `last_start_error_at` |
| `services/debug/handlers/help.dart` | упомянуть поля в /state |
| `docs/api/debug-api-reference.md` | строка /state |
| тесты | стоп с причиной → поле заполнено; clearError не трогает; connected очищает; сериализатор отдаёт оба поля |

## Связанные

- §166 (SnackBar-consume lastError), §042/§043 (diagnostics platform).
- §246 ipv4-падение — повод (docs/spec/tasks/246-preset-rule-array.md).
