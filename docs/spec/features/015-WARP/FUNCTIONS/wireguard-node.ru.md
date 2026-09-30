[English](wireguard-node.md) · [Русский](wireguard-node.ru.md)

# WireGuard-узел WARP — готовый узел из одной регистрации

WireGuard — транспорт мастера «Get WARP» по умолчанию.

| Поле | Значение |
|------|----------|
| Фича | [015-WARP](../FEATURE.ru.md) |
| Обещания | P5, P6, P7, P14 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Превращает WG-регистрацию в готовый узел списка Servers: одиночный сервер со
ссылкой `wireguard://…` (или WG INI с полями AmneziaWG при обфускации),
который пингуется и работает в любом режиме VPN/Proxy. Каждый «Register»
добавляет новый узел — пользователь сам держит несколько вариантов
(endpoint, обфускация) на одной регистрации.

## Параметры

| Параметр | Значение | Дефолт |
|----------|----------|--------|
| Endpoint | `host:port`; список пресетов пула + свободный ввод | `engage.cloudflareclient.com:2408` |
| Persistent keepalive (s) | число; 0/пусто — не писать | 25 |
| Bind to this device (reserved) | вкл/выкл | вкл без обфускации, выкл с ней |
| MTU | 1280 | — |
| `allowed_ips` | `0.0.0.0/0`, `::/0` | — |

## Входы / Выходы

**Входы:** WG-регистрация (свежая или из кэша), ввод мастера.

**Выходы:** endpoint `wireguard` в конфиге: `address` (v4 + v6),
`private_key`, `mtu`, пир с `address`/`port`/`public_key`/`allowed_ips`,
`reserved` (3 байта `client_id`), `persistent_keepalive_interval`.
Тег узла: `🔥☁️ WARP`, `🔥☁️ WARP+`, `🔥⛈️ WARP (AWG 1.5)`,
`🔥⛈️ WARP+ (AWG 1.5)`; занятый — суффикс ` 2`, ` 3`…

## Правила и инварианты

- **Endpoint.** Вписанный не-дефолтный endpoint побеждает и ответ Cloudflare
  (тот всегда отдаёт `engage…:2408`), и endpoint из кэша регистрации.
  Дефолт без обфускации — хост из ответа Cloudflare; дефолт с обфускацией —
  случайный `ip:port` (см. обфускацию). Применённый endpoint пишется в кэш.
  Непустое поле проверяется до запроса: `host:port` (имя, IPv4 или IPv6 в
  скобках; порт 1–65535), иначе снэкбар «Endpoint must be host:port» и
  регистрации нет.
- **Пресеты.** Список Endpoint берётся из `wireguard.endpoints_preset` пула;
  пункт, равный `recommended_endpoint`, помечен «(recommended)» только в меню —
  в поле и в узел уходит чистое значение.
- **reserved.** По умолчанию пишется без обфускации и не пишется с ней
  (привязка к устройству режется DPI); галка переопределяет. Битый
  `client_id` (не 3 байта) — `reserved` не пишется.
- **Keepalive.** Пусто или 0 — ключа нет; без него WG-узел при простое
  теряет NAT-маппинг и деградирует в `err`.
- **Накопление.** Прежние WARP-узлы не удаляются и не обновляются по тегу.
- **Успех.** Снек «Added WARP node» / «Added WARP+ node», конфиг
  перестраивается, мастер закрывается. Неудача сборки узла — «Invalid WARP
  config» / «Invalid WARP config (obfuscated)».

## Границы

- Разбор ссылки и INI — 002-NODE_IMPORT; правка узла потом — 008-NODE_EDITOR.
- v6-endpoint подставляется только рандомом и только при включённом IPv6.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---------|--------|------|
| 1 | [025F](../../../tasks/025F-warp-integration/spec.md) | Released v2.3.0 | Узел из регистрации, `reserved` из `client_id`, MTU 1280 |
| 2 | [135](../../../tasks/135-warp-custom-endpoint-not-overwritten.md) | Done (device-smoke pending) | Свой endpoint не затирается ответом Cloudflare |
| 3 | [137](../../../tasks/137-warp-node-naming.md) | Implemented | Теги с эмодзи, накопление узлов вместо замены |
| 4 | [138](../../../tasks/138-warp-cached-account-ignores-endpoint.md) | Fixed | Выбранный endpoint применяется и к кэшу |
| 5 | [142](../../../tasks/142-warp-reserved-optional.md) | Done (released v2.3.3) | `reserved` опционален, дефолт по обфускации |
| 6 | [304](../../../tasks/304-warp-persistent-keepalive.md) | — | Keepalive 25 с при ручной регистрации |
| 7 | [386](../../../tasks/386-warp-endpoint-preset-combobox.md) | — | Список пресетов у поля Endpoint |
| 8 | [424](../../../tasks/424-warp-preset-recommended-mark-leak.md) | Implemented (unit + widget test) | Пометка «(recommended)» не утекает в значение |
| 9 | [606](../../../tasks/606-audit-591-export-list-tun-warp-dpi-bugs.md) | Done | Свой endpoint проверяется на `host:port` до регистрации |
| 10 | [606](../../../tasks/606-audit-591-export-list-tun-warp-dpi-bugs.md) | Done | Неиспользуемая карточка статуса регистрации удалена; мастер закрывается при успехе |
