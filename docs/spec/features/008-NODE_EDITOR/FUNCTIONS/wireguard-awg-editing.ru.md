[English](wireguard-awg-editing.md) · [Русский](wireguard-awg-editing.ru.md)

# Правка WireGuard / AmneziaWG

| Поле | Значение |
|------|----------|
| Фича | [008-NODE_EDITOR](../FEATURE.ru.md) |
| Обещания | P9 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Даёт исправить свой узел WireGuard или AmneziaWG — ключ, адрес, `Endpoint`,
параметры обфускации — правкой его источника. Отдельной формы с полями
WireGuard нет: правится текст, в котором узел пришёл.

## Параметры

| Источник узла | Где правится | Как хранится тег |
|---|---|---|
| `.conf` (wg-quick INI) | Source, текстом INI | полем записи; INI байт в байт |
| ссылка `wireguard://`, `wg://`, `awg://`, `amneziawg://` | Source, текстом ссылки | во фрагменте `#…` |
| тело sing-box `type: wireguard` | Source, текстом JSON | в `tag` |

Поля обфускации AmneziaWG правятся только как текст — ключами INI/ссылки
или JSON-ключами endpoint'а `wireguard`:

| Уровень | Поля |
|---|---|
| 1.0 | `jc`, `jmin`, `jmax`, `s1`, `s2`, `h1`–`h4` (число) |
| 1.5 | `i1`–`i5`; masquerade `ip`/`id`/`ib` |
| 2.0 | `h1`–`h4` диапазоном `"N-M"`, `s3`, `s4` |
| 3.x | `header_protection_key`, `content_padding_addition`, `rekey_after_time`, `rekey_timeout`, `reject_after_time`, `keepalive_timeout`, `max_handshake_attempts`, `random_trailers`, `disable_cookies` |

Смысл и правила значений — [002, импорт WireGuard / AmneziaWG](../../002-NODE_IMPORT/FUNCTIONS/wireguard-amnezia-import.ru.md).

## Входы / Выходы

**Вход:** текст источника.
**Выход:** новый источник; узел перечитывается; на Settings — Protocol
«AmneziaWG (wireguard)», если у узла есть поля обфускации, иначе
`wireguard`. Уровень AWG (`awg`, `awg1.5`, `awg2`, суффикс `+` за masquerade)
виден в строке узла на главном экране (007).

## Правила и инварианты

- INI сохраняется как есть; строка `DNS` из `[Interface]` в тело не едет
  (002). Тег при Save — полем записи, не в текст.
- Ссылка сохраняется с тегом во фрагменте; параметры, которые ссылка не
  несёт, теряются при переходе ссылка → модель (002).
- Тело sing-box проверяется ядром при сохранении и уходит в конфиг
  дословно: потолок MTU AmneziaWG 1280 к нему не применяется — только
  сообщение (002, P14 там).
- «Edit JSON» у INI или ссылки заменяет источник телом endpoint'а модели —
  необратимо; дальше узел правится как JSON.
- Изменение тела снимает вердикт ядра и включает узел, выключенный за отказ
  ядра (P9).
- WireGuard-тело при проверке ядром кладётся под `endpoints`.
- Своего валидатора полей AWG (диапазоны, взаимоисключение `i1` и
  masquerade) редактор не держит: судят разбор (002) и ядро.

## Границы

- Разбор INI, ссылок, `vpn://`, кламп MTU, коды — 002-NODE_IMPORT.
- Cloudflare WARP со своими полями обфускации — [015-WARP](../../015-WARP/FEATURE.ru.md).
- Состояние endpoint'а (handshake, asleep) — [012-LIVE_STATE](../../012-LIVE_STATE/FEATURE.ru.md) / 009.
- AWG поверх WireGuard в detour разрешён — 006.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [097F](../../../tasks/097F-awg2-amneziawg2/spec.md) | In progress | AWG2; выделенные поля в UI — необязательный follow-up, не сделан |
| 2 | [106](../../../tasks/106-wireguard-slash-key-and-bare-cidr.md) | DONE | `/` в ключе, голый IP → CIDR (разбор) |
| 3 | [110](../../../tasks/110-amnezia-vpn-link-import.md) | Done | Профиль Amnezia `vpn://` (разбор) |
| 4 | [112](../../../tasks/112-awg-ranged-magic-headers.md) | Done | `h1`–`h4` число или диапазон |
| 5 | [130](../../../tasks/130-awg-detour-exclude-wireguard.md) | SUPERSEDED | Подпись «AmneziaWG (wireguard)»; запрет AWG-over-WG снят |
| 6 | [148](../../../tasks/148-awg-version-labels.md) | Implemented | Лейблы уровня `awg` / `awg1.5` / `awg2` и `+` |
| 7 | [243](../../../tasks/243-wg-import-filename-tag.md) | Реализовано, частично заменено §456 | Имя файла `.conf` — тег; правка тега видна в списке |
| 8 | [421](../../../tasks/421-awg3-header-protection-timings.md) | Implemented, device-verified | Поля AmneziaWG 3.0/3.1 |
| 9 | [450](../../../tasks/450-awg-conf-base64-link.md) | Реализовано | `awg://<base64 .conf>` |
| 10 | [456](../../../tasks/456-wg-ini-as-source-tag-in-record.md) | Выпущено v2.24.3 | INI — источник как есть, тег полем записи |
