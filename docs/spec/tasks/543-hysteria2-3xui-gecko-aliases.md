# 543 — hysteria2: ссылки 3x-ui с gecko читаются без потерь

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-09-25 |
| Дата завершения | 2026-09-25 |
| Коммиты | лаунчер `777bb52e` feat(contract): 1.1.54; LxBox — этот коммит |
| Связанные spec'ы | контракт 1.1.54 (`TASKS_LXBOX.md` §50), §358 (gecko) |

## Проблема

Ссылка hysteria2 из 3x-ui с gecko-обфускацией давала три `uri_param_unknown`:
`minPacketSize`, `maxPacketSize`, `security`. Узел поднимался с
`obfs.type=gecko` и паролем, но диапазон размеров пакетов из панели терялся
молча — ядро брало дефолт sing-quic (`geckoDefaultMinPacketSize = 512`).

## Диагностика

3x-ui, `internal/sub/service.go` → `genHysteriaLink`: `security=tls` пишется
в каждую hysteria2-ссылку безусловно; при gecko — `obfs=gecko`,
`obfs-password`, `minPacketSize`, `maxPacketSize` (в коде — «v2rayN's gecko
pair», оба числа только вместе). В реестре контракта ключи назывались
`obfs-min-packet-size`/`obfs-max-packet-size` с прозой «де-факто URI-ключа
нет», ключа `security` у hysteria2 не было. Ядро (сверено сессией ядра)
принимает `obfs {type: "gecko", password, min_packet_size, max_packet_size}`.

## Решение

Контракт 1.1.54 (лаунчер `777bb52e`), `registry/protocols/hysteria2.json`:

- `minPacketSize`/`maxPacketSize` — вторые источники записей
  `obfs-{min,max}-packet-size`; канон эмита, тело и identity не меняются.
  Правило `requires … equals: gecko` срабатывает на обоих написаниях.
- `security` — запись только у hysteria2, `maps_to: null`: `tls` и пустое
  значение молчат; иное — `uri_param_unknown` (`query_name=security`) через
  `on_present` под `when … not_in`. Блок `tls#uri_security` не подключён:
  его ветка `none` сняла бы TLS, обязательный для hysteria2.

В LxBox — синк контракта (`sync_contract.sh --to 777bb52e`); алиасы и запись
`security` исполняет Dart-движок по реестру, правок кода нет.

## Риски и edge cases

- `security=TLS` (другой регистр) даст предупреждение — значение сверяется
  точно; узел при этом работает.
- `vcn` из ссылок 3x-ui не читается ни одной стороной (в реестре нет); `ech`
  у hysteria2 читается блоком `tls#uri` с кодом `ech_ignored`.

## Верификация

- Корпус контракта: `uri/hysteria2/3xui_gecko_camelcase` (без предупреждений),
  `security_non_tls_warn`, `salamander_camelcase_sizes_dropped` — зелёные в
  Go-раннере и Dart-раннере (`test/contract/contract_test.dart`).
- `test/parser/round_trip_test.dart`: ссылка 3x-ui → `obfsMinPacketSize=512`,
  `obfsMaxPacketSize=1200`, `emitRaw` пишет их в `obfs`, предупреждений нет.

## Нерешённое / follow-up

- `ext: mobile` у `obfs-*-packet-size` в реестре устарел (лаунчер читает ключи
  тем же движком) — снять при следующей ревизии.
