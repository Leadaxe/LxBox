# 115 — VLESS flow: honor ссылку, не навязывать vision

| Поле | Значение |
|------|----------|
| Статус | Code-complete в develop (релиз отложен — накопить с другими фиксами) |
| Дата старта | 2026-06-12 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | features/026 (parser v2: vless), tasks/012 (vless packet-encoding), features/097 (XHTTP+Reality) |

## Проблема

Field report: на панели x3-ui у пользователя `flow: none`, но LxBox после
импорта подписки проставляет в конфиг `"flow": "xtls-rprx-vision"`. Клиент
шлёт vision, сервер его не ждёт → подключения нет. Если вернуть `flow:
xtls-rprx-vision` на сервере — работает (совпало). То есть LxBox **сам
навязывает** vision там, где ссылка его не несёт.

## Root cause

Перенесённый из v1 эвристик-костыль в двух парсерах: если flow пуст,
REALITY активна (`pbk`/`security=reality`) и транспорта нет (bare TCP) —
**дописываем** `xtls-rprx-vision`:

- URI: [vless_parser.dart:33-36](../../app/lib/services/parser/uri_parsers/vless_parser.dart)
- Xray JSON: [json_parsers.dart:100-104](../../app/lib/services/parser/json_parsers.dart)

Предположение «REALITY без транспорта ⇒ наверняка vision» неверно: REALITY
на голом TCP штатно работает и **без** vision (`flow: none` — валидный,
распространённый сетап). x3-ui/x-ui share-ссылки для vision **всегда**
прописывают `&flow=xtls-rprx-vision` явно, поэтому отсутствие flow в
ссылке = сервер vision не использует. Наша авто-подстановка ломает ровно
эти рабочие none-конфиги.

## Контракт sing-box (ядро)

`flow` опционален (`option/vless.go`: `Flow string json:"flow,omitempty"`),
принимает ровно два значения:

| Значение | Когда валиден |
|----------|---------------|
| отсутствует / `""` | обычный VLESS — поверх TLS/Reality; **обязательно** при любом транспорте (ws/grpc/httpupgrade/xhttp) или Multiplex |
| `xtls-rprx-vision` | только bare TLS **без** транспорта (XTLS оборачивает сам TCP-поток) |

Пустой flow — «основной» путь (`vless.NewClient(uuid, "", …)` штатно;
`outbound.go` спец-кейсит `Flow == ""` для kTLS-совместимости).
`xtls-rprx-vision` **несовместим** с любым транспортом — в т.ч. XHTTP
(см. `docs/lx-config.md`: «XHTTP is incompatible with XTLS-Vision»).
Исторические `xtls-rprx-direct/origin/splice` ядром выпилены.

## Текущее поведение (что эмитим сейчас)

| Вход | transport | flow в ссылке | эмитим сейчас | верно? |
|------|-----------|---------------|---------------|--------|
| bare TCP + REALITY, без flow | нет | — | **vision** (авто) | ❌ баг |
| XHTTP/ws + REALITY, без flow | есть | — | пусто | ✅ |
| XHTTP/ws + REALITY, flow=vision явно | есть | vision | **vision + transport** | ❌ невалидно, не гасим |
| bare TCP, flow=vision явно | нет | vision | vision | ✅ |

## Решение

`flow` = источник истины — **ссылка**, с нормализацией под контракт ядра.
Две правки в обоих парсерах (URI + Xray JSON):

1. **Убрать авто-подстановку vision** при пустом flow. Нет flow в ссылке →
   flow остаётся пустым → emit поле не пишет
   ([node_spec_emit.dart:39](../../app/lib/models/node_spec_emit.dart):
   `if (s.flow.isNotEmpty)`) → plain VLESS, совпадает с `flow: none`.
2. **Гасить vision при наличии транспорта**: `flow == 'xtls-rprx-vision'
   && transport != null` → `flow = ''` + warning. Vision валиден только на
   bare TLS; с транспортом (ws/grpc/xhttp) — невалидная комбинация, ядро
   её не поднимет. Закрывает явный vision+XHTTP кейс.
3. **Универсальный net на эмиссии** ([node_spec_emit.dart](../../app/lib/models/node_spec_emit.dart),
   `emitVless` + `toUriVless`): `flow` пишется в outbound/share-URI **только**
   когда `transport == null`. Это покрывает ВСЕ пути конструирования
   `VlessSpec` одним местом — включая `parseSingboxEntry` (прямой sing-box
   JSON, читает `flow`/`transport` без guard) и ручную правку, которые
   парсерные guard'ы URI/Xray не трогают. Паттерн десктоп-лаунчера
   (`outboundHasTransport` в `GenerateNodeJSON`).

Сохраняем без изменений: нормализацию `xtls-rprx-vision-udp443` →
`xtls-rprx-vision` + `packet_encoding=xudp` (это валидное явное значение).

### Новый warning

`VisionWithTransportWarning` в [node_warning.dart](../../app/lib/models/node_warning.dart)
(рядом с `DeprecatedFlowWarning`): «flow xtls-rprx-vision несовместим с
транспортом <type> — flow убран». Трассируется в UI как прочие node-warnings.

## Затронутые файлы

- [vless_parser.dart](../../app/lib/services/parser/uri_parsers/vless_parser.dart) — убрать блок 33-36, добавить vision+transport guard.
- [json_parsers.dart](../../app/lib/services/parser/json_parsers.dart) — убрать блок 100-104, тот же guard (`transport != null`).
- [node_spec_emit.dart](../../app/lib/models/node_spec_emit.dart) — `emitVless`/`toUriVless`: flow только при `transport == null` (универсальный net).
- [node_warning.dart](../../app/lib/models/node_warning.dart) — `VisionWithTransportWarning`.

## Locked decisions

1. Ссылка — источник истины; не угадываем flow по наличию REALITY.
2. vision + транспорт = невалидно → гасим flow (не транспорт): транспорт
   несёт сам трафик, vision — лишь обёртка голого TLS; убрать обёртку
   безопаснее, чем ломать транспорт.
3. Без миграции старых persisted-нод: `UserServer`/подписки ре-парсятся
   из rawBody/rawBody-кеша при загрузке — новый парс применится сам.

## Риски и edge cases

- **Размен**: ссылка без flow, но сервер использует vision → после фикса
  не подключится, пока flow не добавлен в ссылку. Принято: нормальные
  x-ui/x3-ui vision-ссылки flow прописывают явно, страдает только кривой
  линк; обратное (ломка рабочих none) — реально репортится.
- Фикстура [singbox_vless_outbound.json](../../app/test/fixtures/json/singbox_vless_outbound.json)
  несёт `flow` явно → не зависит от авто-подстановки, тест не ломается.
- Тест `reality with pbk auto-sets flow when no transport`
  ([vless_test.dart:10](../../app/test/parser/vless_test.dart)) закреплял
  баг — переписать на «flow остаётся пустым».

## Верификация

- Unit [vless_test.dart](../../app/test/parser/vless_test.dart): bare TCP +
  REALITY без flow → flow `''` (бывший auto-vision тест); явный
  flow=vision на bare TCP → vision; `xtls-rprx-vision-udp443` → vision+xudp
  (без изменений); vision + transport (ws/xhttp) → flow погашен + warning.
- Unit [json_parsers_test.dart](../../app/test/parser/json_parsers_test.dart):
  Xray REALITY+tcp без flow → `''`; фикстура с явным flow → vision (как
  было).
- Unit [vless_test.dart](../../app/test/parser/vless_test.dart) — эталонная
  матрица брифа на **эмиссии** (4 строки: bare/transport × flow/none →
  ожидаемый emit); [json_parsers_test.dart](../../app/test/parser/json_parsers_test.dart)
  — raw sing-box JSON flow=vision+transport → emit гасит flow (net). ✅
- `flutter analyze` чистый, полный `flutter test` — 974 passed. ✅
- **`sing-box check` ядром lx.6** на сгенерированных конфигах: VLESS+XHTTP+
  Reality (flow=vision в ссылке → погашен) и bare-TCP+Reality без flow —
  **оба грузятся** (валидный reality-keypair). ✅
- Девайс-smoke с реальным x3-ui REALITY-none → подключение: **pending**
  (войдёт с релизом).
