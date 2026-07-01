# §217 — XHTTP: нормализация невалидных для ядра параметров

> **СТАТУС: РЕАЛИЗАЦИЯ.** Фикс краша «весь конфиг не грузится».

## Симптом (репорт с 4pda)

Туннель не стартует, баннер:
```
Stopped: Failed to start service: … initialize outbound[361]:
create client transport: xhttp: v2ray-xhttp:
uplink_http_method can be GET only in packet-up mode
```
Одна xhttp-нода из подписки роняет **весь** конфиг fatal.

## Первопричина (source-verified с обеих сторон)

- **Ядро** (`transport/v2rayxhttp/meta.go` `normalizeMeta`): часть xhttp-параметров
  валидна только в определённом режиме или из фикс-множества, иначе fatal:
  - `uplink_http_method = GET` — только при `mode = packet-up` (meta.go:105);
  - `uplink_data_placement = header|cookie` — только при `mode = packet-up` (:98);
  - `session/seq_placement`, `uplink_data_placement`, `x_padding_placement`,
    `x_padding_method` — значение вне допустимого множества → fatal.
  - `mode` ядро дефолтит `"" → auto` (client.go:79), т.е. packet-up только явный.
- **Клиент** (§127): парсер эмитил эти поля из ссылки **как есть**. Подписка с
  `uplinkHTTPMethod=GET` без `mode=packet-up` → невалидная для ядра нода →
  весь конфиг падает (как XHTTP-ловушка rc.15, только семантическая).

## Решение

`XhttpTransport.toSingbox()` отзеркаливает `normalizeMeta`: невалидную для
текущего mode / вне-множества комбинацию **не пишет** в конфиг (ядро подставит
свой дефолт), а на каждый сброс добавляет `XhttpParamResetWarning`. Нода остаётся
рабочей на дефолтах, конфиг больше не падает.

Warning течёт в `node.warnings` → **⚠️ в подписке** (Subscription detail → Nodes:
баннер + инлайн-строка на ноде) **и** в AppLog (билдер эмитит warnings). Один
`NodeWarning` — оба канала.

Парсинг остаётся дословным (читаем как есть); коррекция — только при сборке
конфига, где есть warnings-канал.

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| model | `models/node_warning.dart` | `XhttpParamResetWarning` |
| model | `models/transport_spec.dart` | нормализация + warnings в `XhttpTransport.toSingbox` |
| тесты | `test/parser/xhttp_test.dart` | §217: GET+не-packet-up→сброс+warning; +packet-up→сохраняется; enum→сброс |

## Проверка

- `uplink_http_method=GET` + `mode≠packet-up` → поля нет в конфиге + 1 warning. ✓
- то же + `mode=packet-up` → поле сохраняется, 0 warnings. ✓
- `uplink_data_placement=header` без packet-up → сброс + warning. ✓
- невалидный enum placement/method → сброс + warning. ✓
- `flutter analyze` чист; parser-набор зелёный.

## Связанные

- §127 XHTTP full params (источник полей).
- §214 rc.16 (unknown-field ловушка — родственный класс «одна нода роняет всё»).
- §172 heal dangling detour — тот же принцип «деградация вместо fatal».
