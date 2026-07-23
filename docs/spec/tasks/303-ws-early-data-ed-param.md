# §303 — WebSocket early data: `?ed=N` в пути ломает подключение

**Тип:** bugfix (импорт/конвертация) · **Статус:** ✅ реализовано · **Размер:** M · **Область:** parser (URI + JSON) + transport-модель

Xray-ноды массово задают WebSocket early data через хвост пути: `"path": "/api/v2/channel?ed=2560"`. При импорте этот хвост попадает в `transport.path` конфига sing-box дословно, ядро шлёт `GET /api/v2/channel?ed=2560`, сервер отвечает **404** — нода мёртвая.

## Проблема

Срезка `?…`-хвоста была реализована **только для xhttp** ([`transport.dart:85-89`](../../../app/lib/services/parser/transport.dart), §127). Для ws и httpupgrade — ни в одном из путей импорта:

| Путь импорта | Файл:строка | Поведение с `/x?ed=2560` |
|---|---|---|
| URI (`type=ws`) | [`transport.dart:33`](../../../app/lib/services/parser/transport.dart) | копируется дословно |
| URI (`type=httpupgrade`) | [`transport.dart:59`](../../../app/lib/services/parser/transport.dart) | копируется дословно |
| Xray JSON (`wsSettings.path`) | [`json_parsers.dart:202`](../../../app/lib/services/parser/json_parsers.dart) | копируется дословно |
| sing-box JSON (`transport.path`) | [`json_parsers.dart:584`](../../../app/lib/services/parser/json_parsers.dart) | копируется дословно |

Вторая половина бага — **мёртвая модель**. В `WsTransport` были объявлены поля `earlyDataHeaderMaxLen` / `earlyDataHeaderName`, но:

1. их не заполнял **ни один** парсер и ни один тест (grep по `lib/` + `test/` давал только само объявление);
2. первое поле эмитилось как `early_data_header_max_len` — **такого ключа в ядре нет**. В `option/v2ray_transport.go:93` ключ называется `max_early_data` (`uint32`). То есть если бы поле кто-то заполнил, конфиг отвалился бы на unknown-field.

## Решение

`ed=N` из хвоста пути → отдельные поля транспорта; хвост из `path` срезается.

Модель `WsTransport`: `earlyDataHeaderMaxLen` → **`maxEarlyData`** (ключ `max_early_data`), `earlyDataHeaderName` сохраняет имя (ключ `early_data_header_name`, был верным).

**Имя заголовка не подставляем.** Ядро поддерживает оба режима: при пустом `early_data_header_name` early data уходит **в путь** (`conn.go:172`), ровно как это делает Xray для `?ed=`; при заданном — в HTTP-заголовок. Xray-шный `?ed=N` без `Sec-WebSocket-Protocol` в `wsSettings` — это path-режим, поэтому эмитим только `max_early_data`, оставляя header name пустым. Подстановка `Sec-WebSocket-Protocol` (как предлагает issue #96 из `singbox-launcher`) переключила бы режим на header-based и сломала бы совместимость с сервером, который ждёт path-режим. Явный `wsSettings.headers["Sec-WebSocket-Protocol"]` из Xray JSON по-прежнему читается как обычный заголовок.

Хелпер `splitEarlyDataPath(path)` в `transport.dart` (экспортируемый — нужен обоим парсерам):
- нет `?` → `(path, null)`;
- есть `?` → путь до `?`, из query берётся `ed`; нечисловой/отрицательный/отсутствующий `ed` → `null` (хвост всё равно срезается — он не часть пути);
- пустой результат пути → `/`.

Для **httpupgrade** такого поля у транспорта нет (`option/v2ray_transport.go` — только `Path`/`Host`/`Headers`), поэтому хвост просто срезается, `ed` отбрасывается.

Round-trip: `transportToQuery` для ws снова склеивает `path?ed=N`, чтобы экспортированная ссылка не теряла early data.

## Файлы

- `lib/models/transport_spec.dart` — переименование поля + правильный ключ эмита.
- `lib/services/parser/transport.dart` — `splitEarlyDataPath`, ветки `ws` / `httpupgrade`, `transportToQuery`.
- `lib/services/parser/json_parsers.dart` — `_xrayTransportFromStream` (ws), `_transportFromSingbox` (ws + httpupgrade).

## Приёмка

- `vless://…?type=ws&path=%2Fapi%2Fv2%2Fchannel%3Fed%3D2560` → `{"type":"ws","path":"/api/v2/channel","max_early_data":2560}`.
- Xray JSON `"wsSettings":{"path":"/api/v2/channel?ed=2560"}` → то же самое.
- sing-box JSON с уже разделёнными `path` + `max_early_data` → round-trip без потерь.
- `path` без `?` → поведение не меняется, `max_early_data` не эмитится.
- `?ed=abc` / `?ed=-1` / `?foo=1` → хвост срезан, `max_early_data` отсутствует (не 0 и не мусор).
- httpupgrade с `?ed=2048` → `path` очищен, лишних ключей нет.
- `toUri()` для ws с early data возвращает `path=/x?ed=2560`.

**Тесты:** `test/parser/ws_early_data_test.dart` — 12 кейсов (URI, Xray JSON, sing-box JSON, httpupgrade, битый `ed`, round-trip).

## Docs to update

- Release notes — «WebSocket `?ed=N` (early data) больше не ломает подключение: параметр выносится в `max_early_data`».
- `docs/PROTOCOLS.md` — упоминание early data в ws-секции.
