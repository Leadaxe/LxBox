# 038 — `ru-direct` preset: DNS defaults на UDP/Base

| Поле | Значение |
|------|----------|
| Статус | Implemented |
| Дата | 2026-05-06 |
| Связанные spec'ы | [`033 preset bundles`](../features/033%20preset%20bundles/spec.md) |
| Файл изменений | `app/assets/wizard_template.json` |

## Цель

Сменить template-default DNS-параметры для `ru-direct` preset так, чтобы «из коробки» preset максимально стабильно резолвил `.ru` через любой outbound (включая `direct-out` и WG-routerы в РФ).

| var | было | стало |
|---|---|---|
| `dns_server` | `yandex_doh` (HTTPS/443) | **`yandex_udp`** (UDP/53) |
| `dns_ip`     | `77.88.8.88` (Safe-tier) | **`77.88.8.8`** (Base-tier) |

Также:
- Порядок options в `dns_ip` — Base первым (был Safe-первым).
- Порядок `dns_servers` — UDP первым (был DoH-первым).
- Tooltip у `dns_server` укоротили до `"Recommended: Base/UDP — most stable. DoH/DoT may be filtered by ISPs."`

## Root cause: что наблюдалось живьём

Сессия live-диагностики 2026-05-06. Юзер отчёт: «не открывается Tinkoff Investments / ya.ru через VPN». Активная конфигурация: `vpn-1 = "🇫🇷⚡Франция bypass"`, `vpn-2 = direct-out`, ru-direct preset включён с template-default'ами (yandex_doh @ 77.88.8.88, detour=vpn-2).

**Что показали delay-tests через Debug API**:

| endpoint | направление | результат |
|---|---|---|
| `direct-out → https://ya.ru` | direct → 77.88.55.242:443 | **138 ms** ✅ |
| `direct-out → https://8.8.8.8` | direct → Google :443 | **43 ms** ✅ |
| `direct-out → https://77.88.8.88` | direct → Yandex DoH :443 | **error** ❌ |
| `wg-parnas → https://ya.ru` | WG-router в РФ → ya.ru | **312 ms** ✅ |
| `wg-parnas → https://77.88.8.88` | WG → Yandex DoH :443 | **error** ❌ |
| `adb shell ping 77.88.8.88` | ICMP с устройства | **3.7 ms** ✅ |

С Mac (control point) тот же `77.88.8.88` отвечает на все порты (UDP/53, TCP/443, TCP/853 — TLS handshake до `safe.dot.dns.yandex.net` проходит, сервер возвращает HTTP 400 на GET без proper DoH-query — норма). То есть endpoint в природе исправен — отвал был **специфичен для пути юзера** (DPI на 443, либо firewall WG-router'а, либо Yandex Safe DoH ограничивает source IP).

**Цепочка fail'а**:
1. `dns.rules: [{rule_set: ru-domains, server: yandex_doh}]` ⇒ все .ru-домены резолвятся через `yandex_doh`.
2. `yandex_doh` имеет `detour: vpn-2` ⇒ sing-box dial'ит DoH endpoint через outbound vpn-2 (was direct-out, потом wg-parnas).
3. TCP-handshake до `77.88.8.88:443` через любой выбранный outbound не проходит (`endpoint/wireguard[⚙ wg-parnas]: outbound connection to safe.dot.dns.yandex.net:443` — далее тишина в логе).
4. DNS-resolve для `ya.ru`/`api.t-bank-app.ru` фейлится → app получают пустые answer'ы или timeout → `ERR_CONNECTION_REFUSED` в Chrome / "Проблемы с интернетом" в Tinkoff.
5. **VPN1 (Франция bypass) не задет** — там нет .ru-доменов, всё резолвится через `google_doh` (живой).

Юзер вручную сменил Transport на `yandex_udp` и `dns_ip` на `77.88.8.8` (Base) через UI — DNS-resolves сразу пошли (`dns: exchanged A ya.ru → 77.88.55.242` в логах через 32ms), всё .ru заработало.

## Почему UDP/Base, а не другое

- **UDP/53 vs DoH/443**: порт 53 редко режется DPI (universal expectation, Android-стек на 53 ходит постоянно). DoH/443 = HTTPS-обёртка над DNS, ISP-grade DPI на 443 распознаёт SNI=`safe.dot.dns.yandex.net` → может прицельно блокировать. На медленных каналах DoH ещё и +200-500ms TLS handshake.
- **Base (77.88.8.8) vs Safe (77.88.8.88)**: Base — обычный resolver без contentscoring. Safe — Yandex Safe Browsing с фильтрацией malware/phishing. У Safe история «отказывать» на необычных source-IP (особенно через cellular roaming). Base гарантировано отвечает любому запросу. Для preset «route .ru directly» Yandex'овский Safe-фильтр не несёт выгоды — юзер уже сознательно выбрал направить .ru через Yandex.
- **Не google_doh / cloudflare как default**: эти preset'у не подходят семантически — preset завязан на Yandex DNS (split-horizon RU-only ответы), смена резолвера в google поломает причину пресета. Для юзеров, которым Yandex DNS вообще не подходит, в шаблоне есть опция `default_value` пустая → fall-through на default `local_dns_resolver` / `google_doh` (есть в tooltip).

## Не в скопе

- Auto-fallback DoH→UDP на runtime (sing-box `fallback_servers`). Не делаем — добавляет config-bloat и race-cases. Пусть юзер видит в UI один stable transport. На fragile путях DoH блокируется первой же попыткой → fallback не помогает быстро.
- Template-level versioning / migration. Изменение касается только template-default'ов; уже сохранённые `vars_values` в storage юзера приоритетнее template-default'а. Юзеры с явным выбором не затрагиваются.
- UI-rename `title: "Transport"` (не точно, но сейчас не трогаем).

## Эффект на юзеров

| Состояние юзера | Эффект |
|---|---|
| `vars_values.dns_server` сохранён явно (любое значение) | Не затронут. Storage переопределяет template-default. |
| `vars_values.dns_server` отсутствует (template-default fall-through) | На следующем rebuild config'а получит yandex_udp + 77.88.8.8 автоматически. |
| Свежая установка | Новый default. |

**Migration code не требуется** — `vars_values` в storage не меняется, builder читает template-default только когда поле отсутствует.

## Verification

На dev-устройстве после установки APK с этой правкой:

1. **Существующая установка**: `GET /state/rules` для `ru-direct` показывает `vars_values: {outbound: vpn-2, dns_server: yandex_udp, dns_ip: 77.88.8.8}` — то что юзер ранее выбрал явно, **не затронуто**.
2. **Свежая установка** (либо `PUT /rules/{id}` с пустым `vars_values` + `?rebuild=true`):
   - `GET /config` после rebuild содержит:
     ```json
     "dns": {
       "servers": [..., {"tag": "yandex_udp", "type": "udp",
                         "server": "77.88.8.8", "server_port": 53,
                         "detour": "vpn-2"}],
       "rules":   [{"rule_set": "ru-domains", "server": "yandex_udp"}]
     }
     ```
   - `dig @127.0.0.1` (через TUN) для ya.ru → отвечает за <50ms.
   - Browser/Tinkoff к .ru-доменам — работают.
3. **UI dropdown** для Transport в правиле "Russian domains direct" — `Yandex UDP` идёт первым, дефолт.
4. **UI dropdown** для UDP server IP — `77.88.8.8 · Base` первым, дефолт.

## Risks

| Риск | Митигация |
|---|---|
| Юзеры, у кого UDP/53 порезан исходящим (редко, но бывает на корпоративных WiFi) | Tooltip говорит "Leave empty to fall through to default DNS" — fallback на `google_doh` через DoH/443 работает почти везде. Также можно через UI вручную выбрать DoH/DoT. |
| Yandex Base DNS блочит phishing через CSP (для пользователей кто рассчитывал на Safe) | Это никогда не было заявленной фичей preset'а; Safe тут был дефолтным "случайно". Кто хочет Safe — выбирает в UI. |
| Order options в dropdown'ах меняется → confused юзеры | Изменение small UX, не critical. UI dropdown sorting — visual only, value mapping не ломается. |

## Docs to update

- [x] `CHANGELOG.md` — `[Unreleased] → Changed` запись со ссылкой на эту таску.
- [x] `docs/spec/tasks/038-ru-direct-dns-defaults.md` (этот файл).
- [ ] `RELEASE_NOTES.md` / `docs/releases/v1.7.0.md` (или какая будет следующая версия) — короткая bullet "DNS defaults для ru-direct сменили на UDP/Base для бо́льшей resiliency на mobile networks". При bump'е версии.
- [ ] `pubspec.yaml` — bump на следующий patch при release.

Не требуют апдейта:
- `docs/ARCHITECTURE.md` — изменение чисто-data, не структурное.
- `docs/api/debug-api-reference.md` — Debug API не менялось.
- Тесты `test/services/builder/preset_expand_test.dart` / `apply_preset_bundles_test.dart` — все используют явные `varsValues: {dns_server: 'yandex_doh'}`, не template-default → не зависят от этого изменения.
