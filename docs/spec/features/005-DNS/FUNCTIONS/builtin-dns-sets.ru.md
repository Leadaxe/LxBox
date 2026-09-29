[English](builtin-dns-sets.md) · [Русский](builtin-dns-sets.ru.md)

# Встроенные DNS-наборы — шифрованный dns_shield и группа dns_ru для российских доменов

DNS работает без настройки: шифрованная группа `dns_shield` обслуживает всё по умолчанию, а пресет
`ru-direct` даёт российским доменам свою группу `dns_ru`.

| Поле | Значение |
|------|----------|
| Фича | [005-DNS](../FEATURE.ru.md) |
| Обещания | P16 P17 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Даёт рабочий DNS из коробки, без единой настройки: шифрованную группу
`dns_shield` для всего, что не сматчилось, и отдельную группу `dns_ru` для
российских доменов (пресет `ru-direct`, включён по умолчанию). Оба набора —
данные шаблона; пользователь меняет их переменными, а не правкой тел.

## Параметры

**`dns_shield`** (сервер шаблона, `type: group`, `mode: fastest`,
`error_ttl: 5m`, `win_ttl: 5m`) — умолчание `dns.final` и
`route.default_domain_resolver`. Члены:

| Член | Тип | Канал по умолчанию |
|---|---|---|
| `google_doh` | DoH, SNI `dns.google` | Direct |
| `google_dot` | DoT | `vpn-1` |
| `cloudflare_dot` | DoT | `vpn-1` |
| `opendns_doh` | DoH, SNI `dns.opendns.com` | Direct |
| `quad9_doh` | DoH, SNI `dns.quad9.net` | `vpn-1` (зашит) |
| `yandex_dot` | DoT `77.88.8.8`, SNI `common.dot.dns.yandex.net` | Direct |

**`ru-direct` → DNS** (переменные пресета):

| Переменная | Смысл | Умолчание |
|---|---|---|
| `dns_enable` («DNS») | DNS-часть пресета вкл/выкл | вкл |
| `dns_ip` («UDP server IP») | адрес UDP-члена: Base / Safe / Family, v4/v6 | `77.88.8.8` |
| `force_ipv4` («Force IPv4») | AAAA для ru-доменов не отдавать | вкл |
| `outbound` | канал пресета (и UDP-члена) | `direct-out` |

Группа `dns_ru` (`fastest`, `error_ttl 5m`, `win_ttl 5m`) над тремя
членами по независимым путям: `yandex_udp` (`@dns_ip`, через канал
пресета), `yandex_dot` (`77.88.8.88`, SNI `safe.dot.dns.yandex.net`, через
`vpn-1`), `yandex_doh` (`77.88.8.88`, напрямую). DNS-правила пресета: для
`ru-domains` + `ru-services` при Force IPv4 —
`{ip_version: 6, action: predefined, rcode: NOERROR}`, затем
`{server: dns_ru, action: route}`. В маршрутизации Force IPv4 добавляет
`resolve` с `strategy: ipv4_only` перед маршрутом.

## Входы / Выходы

**Входы:** шаблон, значения переменных пресета, активные Направления.
**Выходы:** серверы и правила в `dns.servers` / `dns.rules`; в конфиге
серверы пресета — в пространстве пресета (`ru-direct:dns_ru`,
`ru-direct:yandex_udp`, …).

## Правила и инварианты

- Все члены `dns_shield` объявлены в базовом списке серверов шаблона и
  среди них нет открытого UDP (P16).
- Члены с каналом, которого нет, выпадают по общей политике; группа живёт,
  пока жив хоть один член.
- `dns_enable` выключен — пресет не даёт ни `dns_ru`, ни его правил;
  маршрутизация `ru-direct` работает.
- Force IPv4 работает через DNS-правило пресета: при выключенном
  `dns_enable` глушилка AAAA не действует.
- Выключенный `ru-direct` (маршрутизация) убирает всю DNS-часть.
- Серверы пресета на экране DNS — только чтение, с замком «used by
  <пресет>»; правятся переменными пресета.

## Границы

- Выбор набора по региону пользователя не делается: `ru-direct` включён по
  умолчанию у всех, настройка региона на DNS не влияет.
- Маршрутизация `ru-direct` (rule-set'ы, GeoIP, приложения) —
  [004-ROUTING](../../004-ROUTING/FEATURE.ru.md).
- Пресет Tailscale даёт по серверу MagicDNS на узел — описан у узлов
  Tailscale ([030-TAILSCALE](../../030-TAILSCALE/FUNCTIONS/tailnet-dns-and-routes.ru.md)),
  здесь только тип сервера.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [038](../../../tasks/038-ru-direct-dns-defaults.md) | Implemented | `ru-direct`: UDP и Base-адрес по умолчанию |
| 2 | [045](../../../tasks/045-ru-direct-geoip-fallback.md) | Released | GeoIP-слой `ru-direct` (DNS не меняет) |
| 3 | [117F](../../../tasks/117F-dns-rework/spec.md) | Released | Серверы шаблона с переменными `outbound`/`dns_ip`, «Safe DNS» |
| 4 | [253](../../../tasks/253-preset-dns-rules-array.md) | — | Force IPv4 на DNS-слое у `ru-direct` |
| 5 | [257](../../../tasks/257-dns-enable-unify-and-force-ipv4-visibility.md) | — | Переключатель `dns_enable` у пресета |
| 6 | [354](../../../tasks/354-ru-dns-group.md) | реализовано, device-pending | `dns_ru` — группа из трёх независимых путей |
| 7 | [517](../../../tasks/517-editor-selection-and-dns-shield-udp.md) | Released | Из `dns_shield` убран открытый UDP |
| 8 | [527](../../../tasks/527-dns-shield-yandex-dot-base.md) | Released | Базовая запись `yandex_dot` для члена `dns_shield` |
