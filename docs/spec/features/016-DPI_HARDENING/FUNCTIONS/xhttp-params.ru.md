[English](xhttp-params.md) · [Русский](xhttp-params.ru.md)

# Параметры XHTTP — транспорт Xray XHTTP целиком в sing-box

LxBox читает все параметры XHTTP (SplitHTTP) из ссылок, Xray JSON и sing-box
JSON, включая `extra` и `xmux`, и не пропускает недопустимые значения в ядро.

| Поле | Значение |
|------|----------|
| Фича | [016-DPI_HARDENING](../FEATURE.ru.md) |
| Обещания | P11 P12 P13 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Переносит транспорт XHTTP (в Xray — `xhttp`/`splithttp`) из подписки в
блок `transport` ядра полностью: не только путь/хост/режим, но и
размещение сессии, обфускацию набивкой, тюнинг аплинка и мультиплексор
`xmux`. Сервер Xray ждёт ровно то, что задано в ссылке: потерянный
параметр даёт узел, который соединяется, но не передаёт данные.

## Параметры

Все — в `transport` с `type: xhttp`; в ссылке camelCase (Xray), в
sing-box JSON snake_case; читаются обе формы, camelCase в приоритете.

| Группа | Ключи ядра |
|---|---|
| основа | `path`, `host`, `mode` (`auto`·`packet-up`·`stream-up`·`stream-one`), `headers` |
| сессия/seq | `session_placement` (`path`·`query`·`header`·`cookie`), `session_key`, `seq_placement`, `seq_key` |
| аплинк | `uplink_data_placement` (`body`·`auto`·`header`·`cookie`), `uplink_data_key`, `uplink_chunk_size`, `uplink_http_method` |
| набивка | `x_padding_bytes`, `x_padding_obfs_mode`, `x_padding_key`, `x_padding_header`, `x_padding_placement` (`cookie`·`header`·`query`·`queryInHeader`), `x_padding_method` (`repeat-x`·`tokenish`) |
| тюнинг | `sc_max_each_post_bytes`, `sc_min_posts_interval_ms`, `sc_stream_up_server_secs`, `sc_max_buffered_posts`, `no_grpc_header`, `no_sse_header` |
| `xmux{}` | `max_concurrency`, `max_connections`, `c_max_reuse_times`, `h_max_request_times`, `h_max_reusable_secs`, `h_keep_alive_period` |

Алиасы Xray: `sessionIDPlacement`/`sessionIDKey` → `session_placement`/
`session_key` (канон сильнее алиаса).

## Входы / Выходы

**Входы:** ссылка `type=xhttp|splithttp` с плоскими параметрами и `extra`
(URL-кодированный JSON); Xray `xhttpSettings`/`splithttpSettings`
(с `extra`); sing-box `transport`.
**Выходы:** `transport{type: xhttp, …}` только с заданными полями
(`xmux` — только непустым); коды `xhttp_param_reset`,
`xhttp_mode_forced_packet_up`; в экспортируемую ссылку — плоские
camelCase-поля, отличные от дефолта, без `extra`.

## Правила и инварианты

- Три входа читают один набор ключей; поле добавляется сразу во все.
- `extra` сливается поверх плоских параметров, но: битый/не-объектный
  `extra` игнорируется, узел живёт на плоских; пустое значение из
  `extra` плоское не перекрывает; `host`, `path`, `mode` из `extra` не
  читаются вовсе (так делает Xray). `xmux` вложенным объектом в `extra`
  или JSON разворачивается в те же поля, что плоские ключи.
- `path`: хвост `?…` (`/x?ed=2048`) срезается; без параметра `path`
  ключ не эмитится; явный `path=%2F` → `/`.
- `host` — только из явного `host=`, без подстановки SNI.
- Числа: `30.0` → `"30"`, без экспоненты; диапазон `"N-N"` сохраняется;
  `sc_max_buffered_posts` и `h_keep_alive_period` — целые, `0` значим и
  эмитится, отсутствие — не эмитится.
- Значение вне enum (`mode`, `session_placement`, `seq_placement`,
  `uplink_data_placement`, `x_padding_placement` с учётом регистра,
  `x_padding_method`) снимается с `xhttp_param_reset`, узел жив.
- `uplink_data_placement` = `header`/`cookie` требует `packet-up`: без
  `mode` → `mode: packet-up` с `xhttp_mode_forced_packet_up`; при явном
  другом `mode` снимается placement. `body`/`auto` — при любом режиме.
- `xmux.max_concurrency` и `xmux.max_connections` взаимоисключающи
  (`field_conflict`).
- Эмиссия детерминирована: два прогона дают одинаковое тело.

## Границы

- Разбор ссылки в целом — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.ru.md).
- Сам транспорт, режимы и `xmux` исполняет ядро (ядро: FEATURE 002-XHTTP).
- `downloadSettings` не читается; узлы XHTTP только с `alpn=h3` —
  ограничение транспорта по §127F (в коде не перепроверено); редактора
  полей XHTTP в UI нет (правка — JSON узла).
- VLESS Vision поверх XHTTP — [vless-flow-encryption.md](vless-flow-encryption.ru.md).

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [127F](../../../tasks/127F-xhttp-full-url-params/spec.md) | Реализация | 15 расширенных полей, `extra`, срез `?`-хвоста пути |
| 2 | [214](../../../tasks/214-libbox-rc16-xhttp-fields.md) | Реализация | Ядро с полями XHTTP SPEC 002 v2 |
| 3 | [217](../../../tasks/217-xhttp-normalize-invalid-params.md) | Реализация | Невалидные для ядра параметры не роняют конфиг |
| 4 | [399](../../../tasks/399-xhttp-fields-lost-in-json-branches.md) | Реализовано | JSON-ветки читают тот же набор полей |
| 5 | [410](../../../tasks/410-xhttp-extra-empty-not-clobber.md) | Done | Пустое в `extra` не затирает; `host`/`path`/`mode` только плоские |
| 6 | [416](../../../tasks/416-xhttp-packet-up-guard.md) | Done | header-placement без режима → `packet-up` |
| 7 | [463](../../../tasks/463-contract-w2c-corpus-conformance.md) | Released v2.25.0 | `splithttp` = `xhttp` |
| 8 | [508](../../../tasks/508-xhttp-sessionid-aliases.md) | Released v2.25.1 | Алиасы `sessionIDPlacement`/`sessionIDKey` |
| 9 | [522](../../../tasks/522-kernel-lx9-xmux-local-cancel.md) | Released v2.25.3 | Ядро: брейкер XMUX не считает сбоем локальную отмену |
| 10 | [573](../../../tasks/573-xray-finalmask-tcp-fragment.md) | Released v2.25.7 | `extra.mode`/`path`/`host` читаются без кода |
