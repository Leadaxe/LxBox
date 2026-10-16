# §661 — Статистика: источник и inbound у входящих не через TUN

| Поле | Значение |
|------|----------|
| Тип | Доработка фич [012-LIVE_STATE](../features/012-LIVE_STATE/FEATURE.ru.md) (Conns, Overview) и [028-TRAFFIC_PROFILER](../features/028-TRAFFIC_PROFILER/FEATURE.ru.md) (лента Live), запрос владельца 17.10.2026 |
| Статус | I (implemented): CI и проверка на устройстве — ждут |
| Дата | 2026-10-17 |
| Связанные | §122 (Conns на CommandClient), §204 (routing-строка), §656 (`tunnel-ingress`) |

## Проблема

Экраны статистики строились из допущения, что мы всегда клиент: всё
приходит из TUN, источник — адрес самого устройства, показывать его
незачем. С эндпоинтами (wireguard, tailscale, openvpn-client, openconnect с
`allow_lan`/`allow_gateway`, пресет `tunnel-ingress` §656) и локальными
прокси (`mixed-in`, `sysproxy-in`) соединения приходят и с других входов, с
чужих адресов. По экранам не видно, кто пришёл и через какой вход.

Владелец: писать `ip:port / inbound`, если они не стандартные.

## Данные

Ядро отдаёт в `libbox.Connection` поля `getSource()` (`ip:port`),
`getInbound()` (тег входа), `getInboundType()`. Натив их не передавал.

- `BoxCommandClient.serializeConnections` — добавить `source`, `inbound`,
  `inboundType`.
- `CcConnection` — поля `source`, `inbound`, `inboundType` (пусто на старом
  нативе), геттеры:
  - `isStandardInbound` — `inbound` пуст или равен `tun-in`;
  - `sourceLabel` — `''` для стандартного входа, иначе
    `'<source> / <inbound>'` (если `source` пуст — только `inbound`).
- `TrafficEvent` (профайлер) — поля `source`, `inbound`, заполняются только
  для нестандартного входа; в `toJson` — `source`, `inbound` при наличии;
  `copyWith` копирует.

## Условия показа

Метка `source / inbound` показывается, когда **все** условия:

1. `inbound` не пуст;
2. `inbound` ≠ `tun-in`.

Исключений нет: `mixed-in` и `sysproxy-in` тоже нестандартные (источник
`127.0.0.1:port` или адрес LAN — по нему видно, кто ходит через прокси).
Для `tun-in` источник всегда адрес TUN устройства — не показываем.

## UI

- **Conns, ряд** — третья строка под routing-строкой, только для
  нестандартного входа: `192.168.1.7:51514 / wg-in`, размер 10,
  `onSurfaceVariant`, отступ как у строки 2, ellipsis.
- **Conns, карточка** — группа **Source** перед Destination: строки
  Source, Inbound, Inbound type. Показывается для любого входа, если ядро
  отдало `inbound` (в карточке подробности уместны и для `tun-in`).
- **Stats → Overview, ряд соединения** — к мета-строке
  `TCP · rule · 3m` дописать ` · <sourceLabel>`, если он не пуст.
- **Профайлер Live, ряд** — строка 2 (процесс / `(no owner)`): для
  нестандартного входа дописать ` · <source> / <inbound>`. У трафика шлюза
  процесса нет — строка станет `(no owner) · 10.8.0.2:40112 / wg-in`.
- **Профайлер, карточка события** — группа **Source** перед Destination:
  строки Source и Inbound; только для нестандартного входа (у события
  поля заполнены лишь тогда).

Новых строк l10n нет: подписи групп и строк карточек не переводятся (как
соседние Destination/Network), `(no owner)` уже есть.

## Не делаем

- Группировку и фильтры по источнику/inbound.
- Резолв источника в имя устройства LAN.

## Проверка

- Точечно: тест `CcConnection.fromMap` + `sourceLabel` (файл
  `test/vpn/cc_channel_*`, один затронутый файл).
- На устройстве: соединение с LAN через `mixed-in` или через эндпоинт с
  `allow_lan` — в Conns видна третья строка; обычное через TUN — нет.
