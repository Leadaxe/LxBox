# Разбор share-ссылки

| Поле | Значение |
|------|----------|
| Фича | [002-NODE_IMPORT](../FEATURE.md) |
| Обещания | P1 P4 P5 P10 P15 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Принимает одну строку вида `схема://…` — вставленную руками, отсканированную
или строку списка подписки — и превращает её в узел. Если узла не вышло,
называет причину кодом.

## Параметры

| Схема (написания) | Тип тела ядра | Заметки формы |
|-------------------|---------------|---------------|
| `vless` | `vless` | REALITY включается только по валидному X25519-ключу `pbk`; `flow` берётся из ссылки, vision гасится при транспорте |
| `vmess` | `vmess` | base64(JSON) v2rayN; вторая форма — URL |
| `trojan` | `trojan` | TLS по умолчанию |
| `ss` | `shadowsocks` | SIP002 (base64 или открытый userinfo) и старая base64-форма; плагин SIP003 → `plugin` + `plugin_opts` |
| `hysteria2`, `hy2` | `hysteria2` | obfs `salamander`/`gecko`, полоса с единицей → Мбит/с, `mport` → `server_ports` |
| `tuic` | `tuic` | v5 |
| `anytls` | `anytls` | |
| `socks`, `socks5`, `socks4`, `socks4a` | `socks` | версию несёт написание схемы |
| `proxy-http`, `proxy-https`, `proxy+http`, `proxy+https` | `http` | порт по умолчанию 80 / 443; `https` включает TLS |
| `ssh` | `ssh` | пароль или приватный ключ в ссылке |
| `naive+https`, `naive+quic` | `naive` | порт по умолчанию 443; одиночный userinfo — пароль; голое `naive://` не принимается |
| `wireguard`, `wg`, `awg`, `amneziawg` | endpoint `wireguard` | см. [импорт WireGuard / AmneziaWG](wireguard-amnezia-import.md) |
| `masque` | `masque` | узел WARP, см. [015-WARP](../../015-WARP/FEATURE.md) |
| `vpn://` | endpoint `wireguard` | профиль Amnezia: все WG/AWG-контейнеры |

Набор написаний читается из реестра (`scheme_in` секции ссылки плюс
`aliases` протокола); регистр схемы не значим. Лимит длины — 65536 символов,
у `vpn://` — 524288.

## Входы / Выходы

**Вход:** строка ссылки. **Выход:** узел (тело в форме ядра, имя, исходная
ссылка байт в байт как источник) либо «узла нет» + код для отбраковки.

## Правила и инварианты

- Имя узла — раскодированная ремарка после `#` (управляющие символы
  вычищаются, флаг `🇪🇳` заменяется на `🇬🇧`); без ремарки —
  `<тип тела>-<хост>-<порт>` (для `ss://` это `shadowsocks-…`).
- Разбор никогда не бросает: мусор → «узла нет».
- Исходы без узла и что видит пользователь (через отбраковку):

| Ситуация | Код | Уровень |
|----------|-----|---------|
| Схему не ведёт реестр | `scheme_unsupported`, схема в `value` | error |
| Строка без `://` | — (молча) | — |
| Длиннее лимита | `uri_too_long` | error |
| `vpn://` не распаковался | `form_unrecognized` | error |
| Цель `0.0.0.0` / loopback / `localhost` | `provider_banner_link`, ремарка — сообщение | info |
| Служебная строка `incy://routing/…`, `happ://routing/…` | код реестра | info |
| Обязательного поля нет (`server`, `uuid`) | `field_missing` | error |
| Правило реестра снимает узел | код правила | error |

- Строка `vpn://` внутри списка даёт все контейнеры профиля, как если бы
  профиль был телом целиком.
- Одиночная вставка, не давшая узла, показывает причину; мусорная строка —
  прежнее сообщение без причины (показ — [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md)).

## Границы

- `http://`/`https://` — это адрес подписки, а не узел
  ([001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md)).
- `hysteria://`/`hy://` (v1) реестр объявляет, но модели hysteria v1 в
  приложении нет — узел не создаётся.
- Детали TLS-обфускации и XHTTP — [016-DPI_HARDENING](../../016-DPI_HARDENING/FEATURE.md).

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---------|--------|------|
| 1 | [026F](../../../tasks/026F-parser-v2/spec.md) | Реализовано | Типизированные узлы, разбор ссылки в модель, круг ссылки |
| 2 | [037F](../../../tasks/037F-naive-proxy/spec.md) | Draft | Схема `naive+https` |
| 3 | [106](../../../tasks/106-wireguard-slash-key-and-bare-cidr.md) | DONE | Сырой `/` в ключе WG, голый IP → CIDR |
| 4 | [115](../../../tasks/115-vless-flow-honor-link.md) | Code-complete | `flow` VLESS берётся из ссылки, vision не навязывается |
| 5 | [151](../../../tasks/151-jni-iterator-throw-and-alpn-double-decode.md) | Done | Двойное кодирование ALPN снимается |
| 6 | [169](../../../tasks/169-reality-pbk-validation.md) | Реализовано | REALITY только по валидному X25519 |
| 7 | [222](../../../tasks/222-http-proxy-protocol.md) | — | HTTP(S)-прокси `proxy-http(s)` |
| 8 | [268](../../../tasks/268-directlink-naive-masque-proxy-plus.md) | — | Алиасы `proxy+http(s)`, `naive+https`, `masque` как ссылки |
| 9 | [269](../../../tasks/269-anytls-protocol.md) | — | Схема `anytls` |
| 10 | [303](../../../tasks/303-ws-early-data-ed-param.md) | реализовано | `?ed=N` в пути WS → early data |
| 11 | [320](../../../tasks/320-trojan-subscription-parse-gaps.md) | частично | `ed`/`eh` в query, двойное кодирование пути |
| 12 | [358](../../../tasks/358-hysteria2-obfs-gecko.md) | Реализовано | obfs `gecko` hysteria2 доезжает до тела |
| 13 | [465](../../../tasks/465-naive-single-userinfo-password.md) | Released v2.25.0 | Одиночный userinfo naive — пароль |
| 14 | [475](../../../tasks/475-contract-118-socks-version-by-scheme.md) | Released v2.25.0 | Версию SOCKS несёт схема |
| 15 | [500](../../../tasks/500-direct-link-reject-reason.md) | Released v2.25.0 | Причина отказа одиночного ввода |
| 16 | [506](../../../tasks/506-silent-parse-loss-reasons.md) | Released v2.25.2 | Коды вместо молчаливой потери строки |
| 17 | [512](../../../tasks/512-registry-scheme-set-contract-1149.md) | Released v2.25.2 | Набор схем из реестра, `amneziawg://`, служебные схемы |
| 18 | [514](../../../tasks/514-contract-sync-11152.md) | Released v2.25.2 | Баннер провайдера по цели, socks base64-userinfo |
| 19 | [543](../../../tasks/543-hysteria2-3xui-gecko-aliases.md) | Done | Ссылки 3x-ui с gecko |
| 20 | [562](../../../tasks/562-uri-scheme-dispatch-from-registry.md) | Выполнено | Диспетчер схем только из реестра |
| 21 | [570](../../../tasks/570-close-open-tails.md) | Волна B выполнена | Строка `vpn://` в списке — все контейнеры |
