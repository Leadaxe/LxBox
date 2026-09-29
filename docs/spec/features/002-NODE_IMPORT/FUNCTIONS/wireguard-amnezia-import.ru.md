[English](wireguard-amnezia-import.md) · [Русский](wireguard-amnezia-import.ru.md)

# Импорт WireGuard / AmneziaWG — файлы .conf, ссылки wg/awg и профили Amnezia vpn://

Конфиг WireGuard или AmneziaWG в любой форме распространения становится endpoint `wireguard`
sing-box, а MTU AmneziaWG ограничивается 1280.

| Поле | Значение |
|------|----------|
| Фича | [002-NODE_IMPORT](../FEATURE.ru.md) |
| Обещания | P8 P14 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Превращает конфиг WireGuard или AmneziaWG в endpoint ядра `wireguard` —
из любой из форм, в которых его раздают: файл `.conf` wg-quick, ссылка
`wireguard://`/`wg://`/`awg://`/`amneziawg://` с параметрами, та же ссылка с
base64 от целого `.conf`, профиль Amnezia `vpn://`. AmneziaWG — не отдельный
протокол, а поля обфускации на том же endpoint'е.

## Параметры

| Поле | Откуда | Правило |
|------|--------|---------|
| `PrivateKey`, `Address`, `MTU` | `[Interface]` / query | ключи приводятся к стандартному base64; голый IP → CIDR |
| `PublicKey`, `PresharedKey`, `Endpoint`, `AllowedIPs`, `PersistentKeepalive`, `Reserved` | `[Peer]` / query | порт по умолчанию 51820; `AllowedIPs` по умолчанию `0.0.0.0/0, ::/0`; `Endpoint` — `host:port`, `[IPv6]:port` |
| `Jc`, `Jmin`, `Jmax`, `S1`–`S4`, `H1`–`H4`, `I1`–`I5` | AmneziaWG 1/2 | `H` — число или диапазон `N-M`; перевёрнутый диапазон свопается |
| поля AmneziaWG 3.x | защита заголовка, паддинг, хвосты, тайминги | булевы `on/true/1`; keepalive допускает диапазон |
| `DNS` | `[Interface]` | в тело не едет, код `wgconf_dns_ignored` |
| MTU AmneziaWG | потолок 1280 | см. правила |

## Входы / Выходы

**Вход:** INI-текст (с подсказкой имени — имя файла), ссылка, профиль
`vpn://`. **Выход:** endpoint-узел; источник — сам INI-текст байт в байт
(у ссылки — сама ссылка).

## Правила и инварианты

- **Имя:** комментарий под `[Peer]` сильнее имени файла, имя файла сильнее
  фолбэка; у ссылки — фрагмент, без него — хост `Endpoint`. Имя файла с
  пробелами, кириллицей и скобками сохраняется без процент-каши.
- **Без `Endpoint`, `PrivateKey` или `PublicKey` узла нет** (`field_missing`).
  Битый `PresharedKey` отбраковывает узел.
- **Потолок MTU AmneziaWG — 1280.** Узел с любым AWG-полем: без MTU → 1280
  без кода; выше 1280 → 1280 с кодом `awg_mtu_clamped` (значение автора в
  `value`); ниже — как есть. Обычный WireGuard не трогается. Авторское тело
  sing-box сохраняет своё значение, ставится info-код `awg_mtu_high`.
  У профиля `vpn://` явный `MTU` в `[Interface]` сильнее `last_config.mtu`.
- **Негодное AWG-поле снимается пофакторно**, узел живёт; пересечение
  заголовков, битый ключ защиты или короткий паддинг при ключе снимают узел.
- **Профиль `vpn://`:** распаковываются все контейнеры `awg`/`wireguard`;
  прочие (xray, openvpn, …) пропускаются; профиль без WG/AWG-контейнеров —
  отказ с причиной. Под `vpn://` может лежать и голый `.conf`. Паддинг base64
  необязателен, сжатый и несжатый payload принимаются, DNS-плейсхолдеры
  подставляются из `dns1`/`dns2`. Узлы контейнеров одного профиля получают
  имя с индексом: `имя`, `имя 2`, … по номеру контейнера.
- **`awg://<base64 .conf>`**: один link — один узел, второй `[Interface]`
  игнорируется; base64 без `[Interface]` — отбраковка.
- Одинаковый узел строкой `amneziawg://` и профилем `vpn://` в одном теле
  схлопывается в один с кодом `duplicate`.

## Границы

- Приватный ключ хранится в узле и в его ссылке; копирование — через
  подтверждение ([экспорт](share-link-export.ru.md)).
- Включение/выключение WG-узла на лету, проба — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.ru.md).
- Генерация WARP-узлов — [015-WARP](../../015-WARP/FEATURE.ru.md).
- Ссылкой выражается один пир: тело с несколькими `peers` в ссылку не
  собирается.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---------|--------|------|
| 1 | [019F](../../../tasks/019F-wireguard-endpoint/spec.md) | Реализовано | WireGuard — endpoint, не outbound; ссылка и INI |
| 2 | [097F](../../../tasks/097F-awg2-amneziawg2/spec.md) | In progress | AWG/AWG2: разбор, эмит, круг ссылки, кламп MTU 1280 |
| 3 | [106](../../../tasks/106-wireguard-slash-key-and-bare-cidr.md) | DONE | `/` в ключе, голый IP → CIDR |
| 4 | [110](../../../tasks/110-amnezia-vpn-link-import.md) | Done | Профиль Amnezia `vpn://` |
| 5 | [112](../../../tasks/112-awg-ranged-magic-headers.md) | Done | `H1`–`H4` как число или диапазон |
| 6 | [243](../../../tasks/243-wg-import-filename-tag.md) | Заменено §456 | Имя файла `.conf` — имя узла |
| 7 | [421](../../../tasks/421-awg3-header-protection-timings.md) | Implemented | AmneziaWG 3.x |
| 8 | [450](../../../tasks/450-awg-conf-base64-link.md) | Реализовано | `awg://<base64 .conf>` |
| 9 | [456](../../../tasks/456-wg-ini-as-source-tag-in-record.md) | Выпущено v2.24.3 | Источник — INI-текст; имя из комментария `[Peer]` |
| 10 | [473](../../../tasks/473-contract-115-awg-mtu-by-registry.md) | Released v2.25.0 | Потолок MTU по реестру, коды `awg_mtu_clamped`/`awg_mtu_high` |
| 11 | [481](../../../tasks/481-contract-1111-wg-awg-by-registry.md) | Released v2.25.0 | Ключи WG и правила AWG судит реестр |
| 12 | [506](../../../tasks/506-silent-parse-loss-reasons.md) | Released v2.25.2 | Голый `.conf` под `vpn://` — узел, а не ноль |
| 13 | [538](../../../tasks/538-subscription-dedup-by-identity.md) | Done | `amneziawg://` и `vpn://` одного узла — один узел |
| 14 | [570](../../../tasks/570-close-open-tails.md) | Волна B выполнена | Все контейнеры профиля строкой списка |
