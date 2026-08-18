# §399 — XHTTP: расширенные поля теряются в JSON-ветках парсера

**Тип:** дефект (data loss в конвертере)
**Область:** `services/parser` — `json_parsers.dart`, `transport.dart`
**Связано:** §127 (полный набор полей из URL), §217 (нормализация против ядра),
§321 (переписанный Xray-JSON парсер), §368 (импорт sing-box-конфига)
**Источник:** SPEC 102-B проекта `singbox-launcher` — тот же дефект в Go-ветке
парсера, обнаружен на живых узлах

---

## 1. Проблема

XHTTP разбирается в трёх местах, и наборы полей разошлись:

| Ветка | Точка входа | Читает |
|---|---|---|
| share-URI `vless://…?type=xhttp` | [`transport.dart:160`](../../../app/lib/services/parser/transport.dart) `_parseXhttp` | **полный набор §127**: плоские query + `extra`-JSON, camelCase/snake_case, `_normScRange` |
| Xray-JSON `streamSettings.xhttpSettings` | [`json_parsers.dart:781`](../../../app/lib/services/parser/json_parsers.dart) `_xrayTransportFromStream` | `path`, `host`, `mode` — **три поля** |
| sing-box-JSON `transport.type=xhttp` | [`json_parsers.dart:1210`](../../../app/lib/services/parser/json_parsers.dart) `_transportFromSingbox` | `path`, `host`, `mode`, `x_padding_bytes`, `no_grpc_header`, `headers` — **шесть** |

Модель [`XhttpTransport`](../../../app/lib/models/transport_spec.dart) хранит 21 поле,
эмиттер `toSingbox` умеет эмитить все и уже нормализует их против правил ядра
(§217). Дефект целиком в двух конвертерах: они не читают то, что модель и
эмиттер давно понимают.

### 1.1 Что ломается у пользователя

**Xray-JSON подписка.** Узел с XHTTP собирается в урезанный транспорт, сервер
отвергает HTTP-запрос XHTTP-слоя. По данным SPEC 102-B (реальные узлы,
100 % прогонов `URLTestOutbound`):

| `extra` узла | Что теряется | Ошибка ядра |
|---|---|---|
| `uplinkHTTPMethod: "GET"` (mode `packet-up`) | uplink уходит POST'ом | `v2ray-xhttp: unexpected upload status: 400 Bad Request` |
| `xPaddingBytes: "50-150"` (mode `stream-one`) | ядро подставляет свой padding | `v2ray-xhttp: unexpected status: 400 Bad Request` |
| `xPaddingBytes: "0-0"` | требование «padding выключить» | то же |

Та же нода, поданная ссылкой `vless://…?type=xhttp&extra=…`, работает — расходятся
именно ветки парсера.

**sing-box-JSON (§368-импорт, JSON-редактор, Smart-Paste).** Здесь дефект хуже
чем в Xray-ветке: round-trip не симметричен. Узел с полным набором полей §127
после парсинга обратно в `NodeSpec` теряет 15 из них молча — открыл в редакторе,
сохранил, транспорт срезан. В SPEC 102-B этого случая нет, он специфичен для нас.

### 1.2 Почему разошлось

Ветки писались разными задачами и переносили ровно то, что было нужно на тот
момент: §097 добавил базовый xhttp во все три места, §127 расширил **только**
URI-ветку, §321 переписал Xray-ветку не трогая состав полей. Общего источника
истины нет — `_parseXhttp` работает над `Map<String, String>` и живёт приватным
в `transport.dart`.

---

## 2. Требования

**R1.** Разбор полей XHTTP — **один** хелпер, общий для трёх веток. Добавление
поля в модель покрывает все ветки сразу; расхождение схем не допускается.

**R2.** Xray-ветка читает `xhttpSettings.extra` и переносит его поля наравне с
плоскими. Плоская раскладка читается тоже — Xray допускает обе.

**R3.** При конфликте плоского поля и одноимённого в `extra` — **`extra`
выигрывает** (поведение Xray и URI-ветки, `_mergeXhttpExtra`).

**R4.** Значения нормализуются как в URI-ветке. В JSON часть приходит числами
(`scMaxBufferedPosts: 30`, `uplinkChunkSize: 0`) — эмиттер ждёт строки, и `1e+06`
в конфиге недопустимо. `_scalarToString` + `_normScRange` уже это решают,
их нужно переиспользовать, а не дублировать.

**R5.** `xPaddingBytes: "0-0"` доходит до конфига дословно — это осмысленное
значение (padding отключить), а не «пусто». Сегодня выполняется: поле строковое,
эмиттер проверяет `isNotEmpty`.

**R6.** Деградация вместо поломки: не-объектный или битый `extra` не роняет
разбор узла — узел собирается на плоских полях (поведение `_mergeXhttpExtra`).

**R7.** sing-box-ветка читает те же поля по snake_case-именам, симметрично
эмиттеру `toSingbox`. Round-trip `NodeSpec → JSON → NodeSpec` не теряет полей.

**R8.** Нормализация против правил ядра (§217) остаётся **только** в эмиттере.
Конвертеры читают дословно — иначе warning-канал `NodeWarning` теряет источник
и пользователь не увидит ⚠️ в подписке.

**R9.** `xmux` — вне scope. В модели и эмиттере его нет, поддержка ядром не
подтверждена. Не эмитить полумеру; зафиксировать как отложенное.

---

## 3. Изменения

### 3.1 Общий хелпер разбора

`_parseXhttp` разбивается надвое:

- `xhttpFromMap(Map<String, String> m) → XhttpTransport` — единственное место,
  где перечислены имена полей. Принимает уже слитую карту, читает
  camelCase-с-фолбэком-на-snake_case (`_pick`), нормализует sc-поля.
- `mergeXhttpExtra` — из приватного становится переиспользуемым: карта +
  `extra` (строка URL-encoded JSON **или** уже распарсенный `Map` из JSON-ветки)
  → слитая карта, `extra` в приоритете, битый игнорируется.

URI-ветка становится `xhttpFromMap(mergeXhttpExtra(q))` — поведение прежнее.

### 3.2 Xray-ветка

`_xrayTransportFromStream`, `case 'xhttp'`: `xhttpSettings` приводится к
`Map<String, String>` через `_scalarToString` (вложенные объекты — кроме `extra`
— отбрасываются), сливается с `extra`, подаётся в `xhttpFromMap`. Путь чистится
`splitEarlyDataPath` как в URI-ветке.

### 3.3 sing-box-ветка

`_transportFromSingbox`, `case 'xhttp'`: `raw` приводится к
`Map<String, String>`, `headers` сохраняется отдельно (это `Map`, а не скаляр),
остальное — через `xhttpFromMap`. Имена snake_case ловятся фолбэком `_pick`.

### 3.4 Чего не делаем

- Не трогаем `ws`/`grpc`/`http` в JSON-ветках — у них своих расхождений нет.
- Не добавляем полей в модель.
- Не переносим нормализацию §217 в парсер (R8).

---

## 4. Критерии приёмки

1. Xray-элемент с `xhttpSettings.extra.uplinkHTTPMethod: "GET"` и
   `mode: "packet-up"` даёт в конфиге `"uplink_http_method": "GET"`.
2. `xPaddingBytes: "50-150"` и `"0-0"` доходят до `x_padding_bytes` дословно
   из обеих JSON-веток.
3. Числовое значение в `extra` (`scMaxEachPostBytes: 1000000`) попадает в конфиг
   строкой `"1000000"` — не `1e+06`, не числом.
4. Плоское `xhttpSettings.xPaddingBytes` подхватывается; одноимённое поле в
   `extra` его перекрывает.
5. `extra: "не-json"`, `extra: []`, `extra: 5` — узел разбирается, поля просто
   отсутствуют; warning'ов эмиттера не появляется.
6. Round-trip: `NodeSpec` с полным набором §127 → `toSingbox` → `parseSingboxEntry`
   даёт эквивалентный `NodeSpec`. Тест падает при добавлении поля в модель без
   покрытия ветки.
7. Набор ключей, читаемых тремя ветками, совпадает — зафиксировано тестом над
   общим хелпером, падающим при расхождении.
8. `flutter analyze` (весь проект, включая `test/`) и `flutter test` — чисто.

Устройство: подписка Xray-JSON с XHTTP-узлом на `packet-up`+`GET` проходит
ping без 400. **DEVICE-PENDING** до проверки на живом узле.

---

## 5. Docs to update

| Файл | Что |
|---|---|
| `CHANGELOG.md` | `Unreleased` → Fixed: XHTTP-поля из Xray-JSON и sing-box-JSON подписок больше не теряются |
| `docs/spec/features/127 xhttp-full-url-params/spec.md` | пометка: набор полей теперь общий для трёх веток, точка правды — `xhttpFromMap` |

`ARCHITECTURE.md` — не требуется (структура pipeline не меняется).
