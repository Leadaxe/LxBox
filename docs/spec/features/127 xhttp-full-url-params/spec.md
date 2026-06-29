# Feature 127 — XHTTP full URL params (расширенный splithttp-парсинг)

> **СТАТУС: РЕАЛИЗАЦИЯ.** Расширение XHTTP-парсера ссылок с v1 (6 полей §097)
> до полной клиентской поддержки SPEC 002 v2: `extra`-JSON + placement/keys/
> obfs/tuning. Только parser + model + builder; ядро уже умеет (`with_xhttp`).

## Источник

Ядро sing-box-lx, SPEC 002 v2 — полная клиентская поддержка XHTTP. Справочник
парсера: `SPECS/002-XHTTP_CLIENT_TRANSPORT/URL_PARSING.md` (+ PARAM_MAP.md,
golden fixture §8). Это **client-side парсинг ссылок** — лаунчер/Android-клиент
превращают `vless://…type=xhttp` в `outbound.transport`.

## Что сейчас (v1, §097)

[transport.dart:61](../../../../app/lib/services/parser/transport.dart) xhttp-ветка
читает 6 полей: `path`/`host`/`mode`/`xPaddingBytes`/`noGRPCHeader` (+headers).
`extra`-JSON **не читается вообще**. [XhttpTransport](../../../../app/lib/models/transport_spec.dart)
хранит те же 6 полей. Реальные подписки шлют расширенный набор (placement/obfs)
плоско и в `extra` — наш v1 их теряет → нода-сервер на obfs не обслуживается.

## Что делаем

### Поля (15 новых в XhttpTransport, плоско, omitempty)

JSON-ключи sing-box snake_case; в URL — camelCase (Xray). По URL_PARSING §2:

| Группа | snake_case JSON | camelCase URL | дефолт |
|---|---|---|---|
| session | `session_placement` | `sessionPlacement` | `path` |
|  | `session_key` | `sessionKey` | placement-зав. |
| seq | `seq_placement` | `seqPlacement` | `path` |
|  | `seq_key` | `seqKey` | placement-зав. |
| uplink | `uplink_data_placement` | `uplinkDataPlacement` | `auto` |
|  | `uplink_data_key` | `uplinkDataKey` | placement-зав. |
|  | `uplink_chunk_size` | `uplinkChunkSize` | placement-зав. |
|  | `uplink_http_method` | `uplinkHTTPMethod` | `POST` |
| x-padding obfs | `x_padding_obfs_mode` | `xPaddingObfsMode` | `false` |
|  | `x_padding_key` | `xPaddingKey` | `x_padding` |
|  | `x_padding_header` | `xPaddingHeader` | `X-Padding` |
|  | `x_padding_placement` | `xPaddingPlacement` | `queryInHeader` |
|  | `x_padding_method` | `xPaddingMethod` | `repeat-x` |
| sc-tuning | `sc_max_each_post_bytes` | `scMaxEachPostBytes` | `1000000` |
|  | `sc_min_posts_interval_ms` | `scMinPostsIntervalMs` | `30` |

Все хранятся как `String`/`bool` плоско. omitempty: пустое/false → ключ не
эмитим (у ядра свои дефолты).

### Парсинг `extra` (внутри xhttp-ветки parseTransport)

1. Если `q['extra']` есть → `jsonDecode(extra)` **в try/catch**. Битый/обрезанный
   extra → игнорируем, ссылка живёт на плоских параметрах (НЕ роняем парсинг).
2. Слить extra-ключи в локальную копию `q` (extra в приоритете для своих ключей —
   как Xray). extra-значения приводим к строке (числа/bool → строка).
3. camelCase ИЛИ snake_case (читаем обе формы, как делает v1 для xPaddingBytes).
4. `sc*`-поля: число/float → строка. `30.0` → `"30"` (дробь отбросить),
   `1000000` → `"1000000"`. Транспорт примет и `"N"`, и `"N-N"` — пишем короткое
   `"N"` (URL_PARSING §2.4, послабление подтверждено ядром).
5. `path`: срезать `?…`-хвост (URL_PARSING §4.1) — реальные ноды дают
   `path=/x?ed=2048`.

### server-only / legacy — НЕ маппим

`scMaxConcurrentPosts`, `serverMaxHeaderBytes`, `noSSEHeader`,
`scMaxBufferedPosts`, `scStreamUpServerSecs`, `spx`, `fragment`/`fm`,
`downloadSettings` — опускаем (accept-but-ignore, URL_PARSING §2.5/§6).

### TLS/Reality

Без изменений — `parseVlessTls` уже покрывает security/sni/fp/pbk/sid/alpn/
insecure (§169 reality-валидация). `flow=""` для xhttp (vless_parser уже это
делает для не-tcp транспортов — проверить).

### toUri / round-trip

`transportToQuery` ([transport.dart:244](../../../../app/lib/services/parser/transport.dart))
дописывает новые поля **плоско camelCase**, только если значение `!= дефолт`
(URL_PARSING §8.3) — иначе URI раздувается. `extra` на выходе НЕ генерируем
(разворачиваем в плоские). Инвариант `parseUri(toUri(spec)) ≈ spec` сохраняется
(сравнение по spec, не побайтово по URI).

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| model | `models/transport_spec.dart` | +15 полей в `XhttpTransport` + omitempty в toSingbox |
| parser | `services/parser/transport.dart` | extra-JSON + маппинг 15 полей в xhttp-ветке; transportToQuery дописывает не-дефолтные |
| тесты | `test/parser/xhttp_test.dart` | +extra-парсинг, +obfs-поля, +golden round-trip (§8), +битый extra |
| fixture | `test/fixtures/vless/xhttp_obfs_full.uri` (NEW) | golden-ссылка §8.2 |

## Критерии приёмки

- Golden §8.2-ссылка → `toSingbox` даёт §8.1-блок (все 15 полей корректны).
- Битый `extra` → ссылка парсится на плоских, не роняется.
- `path=/x?ed=2048` → `path=/x`.
- `sc*` число/float → строка.
- Round-trip: `parseUri(toUri(golden)) ≈ golden` (по spec).
- Дефолтные поля НЕ пишутся в toUri (URI не раздут).
- Минимальный `type=xhttp` → дефолты, без лишних ключей (v1-регресс сохранён).
- `flutter analyze` + `flutter test` зелёные.

## Вне скоупа

- UI-редактор этих полей (приходят из подписок, руками не вводятся).
- HTTP/3 (`alpn=h3`-only ноды) — архитектурное ограничение транспорта.
- XHTTP server/inbound, xmux, downloadSettings — вне SPEC 002.

## Связанные

- §097 — XHTTP v1 (6 полей, база). §169 — reality pbk-валидация.
- §151 — нормализация ALPN. Ядро: SPEC 002 v2 (URL_PARSING.md / PARAM_MAP.md).
