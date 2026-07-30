# §320 — четыре потери при импорте ws-подписок: `ed`/`eh` в query, ALPN поверх ws, ECH, двойное кодирование пути

**Тип:** bugfix (импорт/конвертация) · **Статус:** ✅ реализовано · **Размер:** M · **Область:** parser (URI + JSON) + tls/transport-модель

Разбор публичной trojan-подписки (`arshiacomplus/v2rayExtractor`, 105 узлов) показал: парсер не отбрасывает ни одной строки, все 105 дают конфиг. Но у 10 узлов конфиг **неверный** — четыре независимых потери параметров. Пять из них не подключатся гарантированно.

Отдельно зафиксировано (не баг, чинить нечего): 78% подписки — один провайдер (пароль `humanity`, путь `/assignment`, 6 CDN-хостов), парсится корректно. Массовая неработоспособность такой подписки — состояние инфраструктуры провайдера, не парсинг.

## Проблема 1 — `ed` / `eh` отдельными query-параметрами (2 узла, коннект сломан)

§303 научил парсер читать early data **только из хвоста пути** (`path=/x?ed=2560`). Но часть генераторов кладёт то же самое плоскими параметрами:

```
trojan://Aimer@167.68.4.199:2053?ed=2560&eh=Sec-WebSocket-Protocol&path=%2F%3Fproxyip%3Dts.hpc.tw&type=ws
→ {"type":"ws","path":"/","headers":{"Host":"…"}}      // ed и eh потеряны
```

Потеря `eh` — то, что ломает коннект. В [`conn.go:172`](../../../../sing-box-lx/transport/v2raywebsocket/conn.go) ядро при пустом `early_data_header_name` дописывает base64 **в конец пути** (`requestURL.Path += earlyDataString`), а сервер с `eh=Sec-WebSocket-Protocol` ждёт их в заголовке. Клиент шлёт мусорный путь → 404.

Здесь нет противоречия с §303, где path-режим оставлен намеренно: §303 говорит «не подставлять имя заголовка, которого в ссылке нет». Явный `eh=` в ссылке — это и есть указание провайдера использовать header-режим.

## Проблема 2 — ALPN `h2`/`h3` поверх ws (3 узла, коннект сломан)

```
trojan://humanity@45.130.125.158:443?alpn=h3%2Ch2%2Chttp%2F1.1&type=ws&…
→ "alpn":["h3","h2","http/1.1"]
```

ALPN проносится дословно. Сервер согласует `h2` (или `h3`), после чего WebSocket-апгрейд поверх HTTP/1.1 не проходит. WebSocket в sing-box — только HTTP/1.1 (`ws.Dialer.Upgrade` в [`client.go:93`](../../../../sing-box-lx/transport/v2raywebsocket/client.go)); `httpupgrade` — тоже HTTP/1.1 по определению.

Мусор происхождением из vless/vmess-шаблонов, где ALPN копируют в ссылку независимо от транспорта.

## Проблема 3 — `ech` / `echfq` молча отбрасываются (4 узла, теряется маскировка SNI)

```
?ech=ip.gs%2Budp%3A%2F%2F8.8.8.8      →  в конфиг не попадает, warning'а нет
?ech=encryptedsni.com%2Budp%3A%2F%2F8.8.8.8
?echfq=none
```

Коннект от этого не ломается (сервер ECH не требует), но теряется ровно то, за чем ноду и берут — сокрытие SNI от DPI. И теряется молча, что хуже самой потери.

Xray-формат: `<query-name>+<resolver-URL>`. Левая часть — имя для HTTPS-DNS-запроса, отличное от SNI (у всех 3 узлов так и есть: `ech=ip.gs` при `sni=www.ignitelimit.com`). Это в точности `query_server_name` ядра.

Модель ядра ([`common/tls/ech.go:27-55`](../../../../sing-box-lx/common/tls/ech.go)): при пустом `config`/`config_path` ядро **само** тянет ECHConfigList из DNS HTTPS-записи, спрашивая `query_server_name` (а при пустом — `server_name`). Значит для импорта достаточно `{"enabled":true,"query_server_name":"<левая часть>"}`.

**Правая часть (resolver) отбрасывается осознанно:** в `OutboundECHOptions` поля под свой резолвер нет — ядро идёт через общий `dnsRouter` (`ech.go:151`). Пробрасывать некуда, и подмена глобального DNS ради одного узла была бы хуже потери. Отбрасывание — с `NodeWarning`, а не молча.

`echfq=none` — Xray-специфичный `pq-signature-schemes` флаг; в ядре парная опция помечена `Deprecated: not supported by stdlib` и при `true` **роняет конфиг** (`ech.go:38-40`: «legacy ECH options are deprecated… removed in sing-box 1.13.0»). Игнорируем полностью — ни в конфиг, ни в warning.

## Проблема 4 — двойное percent-кодирование пути (1 узел, коннект сломан)

```
path=%2F%252Fassignment  →  queryParameters даёт /%2Fassignment  →  в конфиг как есть
```

Сервер ждёт `//assignment`. `Uri.queryParameters` декодит ровно один раз — остаточное `%2F` уходит в путь дословно. Тот же корень, что у §151 (ALPN `http%252F1.1`), и лечится тем же приёмом.

Родственные, но **валидные** формы, которые трогать нельзя:
- `path=//assignment` — двойной слэш легален, сервер именно его и ждёт (2 узла);
- `path=Telegram🇨🇳` без ведущего `/` — ядро само добавляет слэш ([`client.go:55`](../../../../sing-box-lx/transport/v2raywebsocket/client.go)).

## Решение

### `ed`/`eh` из query (проблема 1)

`splitEarlyDataPath` остаётся источником для path-формы. Поверх него — чтение плоских `ed`/`eh`, **приоритет у хвоста пути** (он специфичнее: относится к конкретному пути, а не к ссылке целиком).

```
ed  := хвост пути ?? query['ed']          // положительное целое, иначе null
eh  := query['eh']                        // непустая строка, иначе null
```

`eh` без `ed` — не сирота: ядро включает early-data-режим по `max_early_data > 0`, имя заголовка без размера не значит ничего. Такой `eh` игнорируем.

Для **httpupgrade** оба параметра отбрасываются как раньше (early data у него в ядре нет).

### ALPN × транспорт (проблема 2)

Фильтр применяется на **эмите**, не на парсинге: `TlsSpec` хранит то, что было в ссылке (round-trip и вкладка Source не должны врать), а `alpn` в конфиг отдаётся уже отфильтрованным по фактическому транспорту узла.

Для `ws` / `httpupgrade`: из списка убираются все значения кроме `http/1.1`. Пустой результат → ключ `alpn` не эмитится вовсе (ядро подставит своё). Каждое снятое значение → `NodeWarning`.

Транспорт знает про свой ALPN сам — новый геттер на `TransportSpec`, чтобы правило не расползлось по протоколам:

```dart
sealed class TransportSpec {
  /// ALPN-идентификаторы, совместимые с транспортом; null = ограничений нет.
  List<String>? get compatibleAlpn => null;   // grpc/http/h2/xhttp — не ограничиваем
}
final class WsTransport … {
  @override List<String>? get compatibleAlpn => const ['http/1.1'];
}
final class HttpUpgradeTransport … {
  @override List<String>? get compatibleAlpn => const ['http/1.1'];
}
```

Применяется во всех протоколах, где транспорт и TLS соседствуют: trojan, vless, vmess (эмит через общий хелпер, а не копипастой в каждом `emit*`).

### ECH (проблема 3)

Новое поле `TlsSpec.ech` — отдельный класс, а не строка (в ядре это объект с четырьмя полями; строкой пришлось бы парсить на каждом эмите):

```dart
class EchSpec {
  final String queryServerName;   // '' = ядро спросит server_name
  Map<String, dynamic> toSingbox() => {
    'enabled': true,
    if (queryServerName.isNotEmpty) 'query_server_name': queryServerName,
  };
}
```

Парсинг `ech=<name>+<resolver>`: левая часть до первого `+` → `queryServerName`; `+resolver` при наличии → `EchResolverIgnoredWarning`. Значение без `+` — целиком имя. Пустое/`none` → ECH не включаем.

`echfq` не читаем (см. выше).

**§221 и round-trip.** Инвариант `parseUri(spec.toUri()) ≈ spec` ([`node_spec.dart:120`](../../../app/lib/models/node_spec.dart)) требует обратного хода: `toUri*` для протоколов с TLS отдаёт `ech=<queryServerName>`. Узлы персистятся как URI-строки, так что без этого ECH терялся бы при первом же пересохранении. Отдельного ключа в storage-allowlist не появляется — поле живёт внутри URI.

### Двойное кодирование пути (проблема 4)

Хелпер `decodeResidualPercent(raw)` рядом с `splitEarlyDataPath` — та же защита, что в `_normalizeAlpn` (§151), но для пути: до 2 проходов декодирования, пока значение меняется. Отличие от ALPN — **валидность не проверяем и значений не выбрасываем**: путь может содержать что угодно, включая эмодзи (`path=Telegram🇨🇳`) и `//`.

Порядок в ws-ветке: сначала снять остаточное кодирование, потом срезать `?ed=`-хвост (иначе `%3Fed%3D2560` не распознается как хвост).

## Файлы

- `lib/models/tls_spec.dart` — `EchSpec`, поле `ech` в `TlsSpec` (+ `copyWith`/`==`/`hashCode`), фильтр ALPN в `_toSingbox`.
- `lib/models/transport_spec.dart` — геттер `compatibleAlpn` на `TransportSpec` + переопределения у `WsTransport` / `HttpUpgradeTransport`.
- `lib/models/node_spec_emit.dart` — общий хелпер эмита TLS с ALPN-фильтром по транспорту; `ech=` в `toUri*`.
- `lib/models/node_warning.dart` — `IncompatibleAlpnWarning`, `EchResolverIgnoredWarning`.
- `lib/services/parser/transport.dart` — `ed`/`eh` из query, `decodeResidualPercent`, парсинг `ech` в `parseTrojanTls`/`parseVlessTls`.
- `lib/services/parser/json_parsers.dart` — `wsSettings.ed` / `.eh` из Xray JSON.

**ECH в JSON-путях не реализован осознанно.** У Xray-JSON своя схема ECH
(`tlsSettings.echConfigList` — PEM/base64 самого конфига, а не `name+resolver`),
и в разобранной подписке её нет ни в одном виде. Реализовать «по аналогии»
значило бы угадывать формат; берётся отдельной задачей, когда появится живой
образец. sing-box-JSON путь уже читает `early_data_header_name` штатно.

## Приёмка

Проблема 1:
- `?ed=2560&eh=Sec-WebSocket-Protocol&type=ws` → `{"max_early_data":2560,"early_data_header_name":"Sec-WebSocket-Protocol"}`.
- `path=/x?ed=1024` + `ed=2560` в query → `max_early_data:1024` (хвост пути в приоритете).
- `?eh=X` без `ed` → ни одного из двух ключей.
- `?ed=abc` / `ed=-1` / `ed=0` → ключей нет.
- httpupgrade с `ed`/`eh` в query → путь чист, ключей нет.
- `toUri()` возвращает и `path=/x?ed=N`, и `eh=` (когда header-режим).

Проблема 2:
- ws + `alpn=h3,h2,http/1.1` → `"alpn":["http/1.1"]` + `IncompatibleAlpnWarning`.
- ws + `alpn=h2` → ключа `alpn` нет вовсе + warning.
- ws + `alpn=http/1.1` → без изменений, без warning.
- grpc/h2/xhttp + `alpn=h2` → без изменений (не ограничиваем).
- `TlsSpec.alpn` после парсинга хранит исходный список (round-trip цел).

Проблема 3:
- `ech=ip.gs+udp://8.8.8.8` → `"ech":{"enabled":true,"query_server_name":"ip.gs"}` + `EchResolverIgnoredWarning`.
- `ech=ip.gs` → тот же ech-блок, без warning.
- `echfq=none` → ни ech-блока, ни warning.
- `ech=` / `ech=none` → ech-блока нет.
- round-trip: `parseUri(toUri())` сохраняет `queryServerName`.

Проблема 4:
- `path=%2F%252Fassignment` → `"path":"//assignment"`.
- `path=//assignment` → `//assignment` (не «схлопывается»).
- `path=Telegram🇨🇳` → как есть (ядро добавит слэш).
- `path=%2F%253Fed%253D2560` (двойное кодирование хвоста) → путь `/`, `max_early_data:2560`.

Регресс: `flutter test` целиком + `flutter analyze` по всему проекту (§CI — не только `lib/`).

**Тесты:** `test/parser/ws_query_early_data_test.dart`, `test/parser/alpn_transport_filter_test.dart`, `test/parser/ech_import_test.dart`, `test/parser/path_double_encoding_test.dart`.

## Docs to update

- `docs/PROTOCOLS.md` — ECH в TLS-секции; ограничение ALPN для ws/httpupgrade.
- Release notes — «ECH из подписок больше не теряется; ALPN `h2`/`h3` на WebSocket-узлах больше не ломает подключение; early data в форме `?ed=&eh=` распознаётся».
