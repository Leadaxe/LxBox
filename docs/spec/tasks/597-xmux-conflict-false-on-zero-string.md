# §597 — Ложный `field_conflict` xmux при `maxConcurrency: "0"`

| Поле | Значение |
|------|----------|
| Тип | B (баг) |
| Статус | P (в работе) |
| Фича | [001-SUBSCRIPTIONS](../features/001-SUBSCRIPTIONS/FEATURE.ru.md) |
| Дата | 2026-09-30 |
| Связанные | §595, корпус `73-github-full` |

## Проблема

В корпусе `73-github-full` (подписка OVI-vpn) xhttp-узел с
`extra={…"xmux":{"maxConcurrency":"0","maxConnections":"4-8",…}}` получает
предупреждение `field_conflict@transport.xmux.max_concurrency`.

По реестру (`transports.json`, запись `max_concurrency`) конфликт судится по
значению, как в ядре: он есть, только когда оба поля больше нуля; `"0"` и
`"0-0"` значат «не задано». Здесь `max_concurrency` = `"0"`, значит конфликта
нет. Эмит при этом правильный (`max_connections: "4-8"`, `max_concurrency`
нет), а предупреждение ложное: человек видит «конфликт», которого нет.

Пример узла — строка корпуса с `path=/api/v2/session/open` и
`host=shprcdn.net` (`app/test/fixtures/public_subscriptions/bodies/73-github-full.txt.gz`).

## Решение

Найти, почему предикат «оба заданы» считает `"0"` заданным на этом узле
(после §595 `0.0` из слоя `extra` печатается как `"0"`; здесь значение изначально
строка `"0"`). Кандидаты: предикат `_allZeroNumeric` и порядок слоёв
`extra`/query в `interpreter.dart`. Нуль в любом виде (`0`, `0.0`, `"0"`,
`"0-0"`, `[0,0]`) — «не задано», конфликта нет, предупреждения нет.

Контракт (`app/assets/contract`, `app/contract`) не трогать; если без
правки контракта не обойтись — остановиться и описать нужную правку.

## Критерии приёмки

1. Узел из корпуса выше: нет `field_conflict`, эмит не меняется
   (`max_connections: "4-8"`, `max_concurrency` отсутствует).
2. Настоящий конфликт (`maxConcurrency:"16-32"` + `maxConnections:"4-8"`)
   по-прежнему даёт `field_conflict`.
3. Юнит-тест на оба случая + нули во всех видах.
4. `expected.json` корпуса — отдельным коммитом оркестратора.
