[English](debug-api-access.md) · [Русский](debug-api-access.ru.md)

# Доступ через Debug API — журнал, поток и запись по маршрутам `/profiler/*`

Те же журнал и запись, что на вкладке Profiler, доступны с компьютера по
HTTP через Debug API.

| Поле | Значение |
|------|----------|
| Фича | [028-TRAFFIC_PROFILER](../FEATURE.ru.md) |
| Обещания | P17 |
| Состояние | ✅ написана по коду, 2026-09-29 |

## Что делает

Даёт снять журнал профайлера и управлять записью без экрана: из `curl`,
скрипта или агента на компьютере. Маршруты читают тот же буфер и дёргают ту
же запись, что вкладка: старт по API виден на экране как «Recording…», старт
на экране виден в `/profiler/live/state`.

## Параметры

| Маршрут | Метод | Ответ |
|---------|-------|-------|
| `/profiler/live/start` | POST | `{ok, recording: true, started_at}`; повторный вызов — ничего |
| `/profiler/live/stop` | POST | `{ok, recording: false}`; повторный вызов — ничего |
| `/profiler/live/state` | GET | `{recording, started_at, buffer_count, unattributed_count, banner_active}` |
| `/profiler/live?seconds=N` | GET | `{window_seconds, count, events}` — события за последние N с (1…600, дефолт 60) |
| `/profiler/live/stream` | GET | SSE `event: traffic_event` с событием в `data` |
| `/profiler/live/unattributed` | GET | `{count, recent_count_30s, banner_active, events}` — кольцо без владельца |

## Входы / Выходы

**Входы:** HTTP-запросы с токеном Debug API ([027-DEBUG_API](../../027-DEBUG_API/FEATURE.ru.md)).

**Выходы:** JSON события в той же форме, что экспорт: `ts`, `kind`,
`domain`, `cname_chain`, `ip`, `port`, `outbound_chain`, `detour_chain`,
`up_bytes`, `down_bytes`, `duration_ms`, `process`, `network`, `rule`,
`confidence`, `matched_via`, `shown_because`, `dns_record_type`, `issues`,
`extra` (сервер, тип сервера, источник, трасса группы).

## Правила и инварианты

- Неверный метод — ошибка запроса; неизвестный путь под `/profiler/` — «не
  найдено». Старые маршруты сессий (`/profiler/start`, `/stop`, `/active`,
  `/sessions`, `/session/<id>`, `/stream`, `/secondary-packages`) удалены
  (§288).
- Подписка на поток безопасна без записи, но пуста: события идут только
  после старта.
- `unattributed_count` и `banner_active` считают только сбои за 30 с, как и
  баннер на экране; `events` кольца отдают всё без владельца.
- Поток SSE без возобновления по `Last-Event-ID`: оборванный клиент
  подписывается заново и продолжает с текущего момента.

## Границы

- Транспорт, токен, включение — 027-DEBUG_API; все маршруты — его
  [карта маршрутов](../../027-DEBUG_API/FUNCTIONS/route-map.ru.md) и
  [справочник Debug API](../../../../api/debug-api-reference.md).
- Окно хранения, фильтр и группировка по API не управляются.
- Снимок ограничен 600 с независимо от окна хранения.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---------|--------|------|
| 1 | [044F](../../../tasks/044F-per-app-traffic-profiler/spec.md) | Implemented v1.7.0 | Маршруты профайлера в Debug API |
| 2 | [048](../../../tasks/048-perapp-trace-attribution-gaps.md) | Done | `/profiler/live*`: снимок, поток, кольцо без владельца |
| 3 | [288](../../../tasks/288-remove-per-app-trace-tab.md) | complete | Маршруты сессий удалены |
| 4 | [315](../../../tasks/315-dns-group-trace-in-profiler.md) | реализовано | `extra` сериализуется — API видит сервер и трассу группы |
