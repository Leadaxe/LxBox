# 152 — Connections: детальный bottom sheet по тапу

| Field | Value |
|------|----------|
| Status | Done |
| Started | 2026-06-21 |
| Trigger | На экране Statistics → Conns строки тайла обрезаются `TextOverflow.ellipsis` (host, chain, process, rule) — длинные значения не влезают в экран, полной информации нет нигде. Нужно по клику открывать окно с полной инфой о соединении. |
| Related | [connections_screen.dart](../../../app/lib/screens/connections_screen.dart) (`ConnectionsView` — embeddable список в `StatsScreen`); [clash_api_client.dart](../../../app/lib/services/clash_api_client.dart) (`fetchConnections`/`closeConnection`); [format_utils.dart](../../../app/lib/services/format_utils.dart) (`formatBytes`/`formatDuration`/`formatTime`) |
| Files touched | `app/lib/screens/connections_screen.dart` (тайл → tappable), `app/lib/screens/connections_screen/connection_detail_sheet.dart` (new) |

## Проблема

`_buildTile` в [connections_screen.dart](../../../app/lib/screens/connections_screen.dart)
показывает 4 строки, все с `overflow: TextOverflow.ellipsis`:

- host\:port (Row 1)
- process (Row 2)
- chain (Row 3)
- network/type · rule · duration (Row 4)

Длинные host / proxy-chain / processPath / rulePayload режутся `…`. Поля
`metadata` (sourceIP, destinationIP, sniffHost, dnsMode, …) не показываются
вообще. Юзер не может прочитать полную инфу о соединении — в т.ч. для
багрепортов на форум.

## Что сделано

### 1. Тайл стал tappable

`_buildTile` обёрнут в `InkWell` с `onTap` → открывает
`showConnectionDetailSheet(context, conn, onClose:)`. Список, поллинг,
accumulate/closed-логика, close-иконка в тайле — без изменений.

Иконка-стрелка слева от host\:port (`→`/`⇄` для tcp/udp) **убрана** из Row 1
тайла — тип соединения неочевиден без подписи и уже дублируется в Row 4
(`network/type`). В заголовке sheet — аналогично без иконки.

### 2. Новый bottom sheet — `connection_detail_sheet.dart`

`showModalBottomSheet(isScrollControlled: true)` + `DraggableScrollableSheet`
(initial 0.6, max 0.95) — нативный для Android, не перекрывает весь экран,
закрывается свайпом.

**Содержимое** — сгруппированные `label : value`, рендерятся только непустые
поля (нет риска показать мусор), без ellipsis (длинное переносится `softWrap`),
value моноширинным. Тап по строке → копирует значение (SnackBar «Copied»).

Группы — **строго по контракту ядра sing-box-lx**
([clashapi/trafficontrol/tracker.go](../../../../sing-box-lx/experimental/clashapi/trafficontrol/tracker.go)
`TrackerMetadata.MarshalJSON`), сверено по исходнику:

- `metadata` = `{network, type, sourceIP, destinationIP, sourcePort,
  destinationPort, host, dnsMode, processPath}`
- top-level = `{id, upload, download, start, chains, rule, rulePayload}`

Апстрим-Clash поля (`sniffHost`, `destinationGeoIP`/`IPASN`, `uid`,
`inboundName`/`User`, `process`) наш форк **не сериализует** — не показываем,
иначе пустые секции / код-мусор. `dnsMode` хардкод `"normal"`, `rulePayload`
всегда `""` (не показываем).

| Группа | Поля |
|---|---|
| Заголовок | host\:port или destIP\:port, live/closed badge (без иконки — тип соединения виден в строке Network) |
| Destination | `host`, `destinationIP`, `destinationPort` |
| Source | `sourceIP`, `sourcePort` |
| Network | `network`, `type` (= inbound, подпись «Inbound»), `dnsMode` |
| Process | `processPath` (для Android = package name + опц. uid/user) |
| Routing | `chains` (построчно, без `…`), `rule` |
| Traffic | upload/download — `formatBytes` + точные байты в скобках |
| Timing | `start` (дата + `formatTime`), duration (`formatDuration`) |
| ID | `id` |

**Footer** (sticky):

- **Copy JSON** — весь `conn` pretty-JSON в буфер (для багрепортов).
- **Close** — `onClose(id)` (переиспользует `_ConnectionsViewState._closeConnection`
  + рефреш) и закрывает sheet; disabled если `closed` или `id` пустой.

Sheet получает статичный снимок `conn` на момент тапа — для деталей живое
обновление не нужно (список и так поллится сзади).

## Почему так, а не иначе

- **Bottom sheet, не fullscreen-dialog** — не перекрывает список, нативный жест
  закрытия, легче вернуться к скроллу. Совпадает с паттерном проекта
  (`wifi_saved_picker_sheet`, `user_rule_editor_sheet`, `home_menus`).
- **Рендер только непустых полей** — Clash/sing-box `/connections` отдаёт
  разный набор `metadata` в зависимости от inbound/sniff/process-настроек;
  показывать пустые `label :` = шум.
- **Снимок, не реактивный stream** — деталь открывается на конкретный момент;
  тащить per-conn подписку ради окна избыточно, список сзади и так живой.
- **Переиспользование `formatBytes`/`formatDuration`/`formatTime`** (§084 H4) —
  не плодить локальные форматтеры.

## Acceptance

- [x] Тап по тайлу открывает sheet с полной инфой, длинные значения не режутся.
- [x] Показаны source/dest IP\:port, host, network/inbound, dnsMode,
      processPath, полная chain, rule, точные байты, start/duration, id.
- [x] Тап по строке копирует значение; Copy JSON копирует весь conn.
- [x] Close из sheet закрывает соединение и обновляет список; disabled для
      уже закрытых.
- [x] Поллинг/accumulate/close-в-тайле не затронуты.
