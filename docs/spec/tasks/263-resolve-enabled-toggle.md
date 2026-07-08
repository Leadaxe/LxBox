# §263 — тумблер «Resolve destination IP» (гейт глобального route-resolve)

**Статус:** Реализовано, device-verified (CPH2411, 08.07.2026) — FakeIP + resolve_enabled=false
на холодном рестарте: `router: lookup` в чёрную дыру пропали, трафик держится на fake-IP.
**SUPERSEDED §264** — `resolve_enabled` переехал из секции Network в locked-пресет
`traffic-processing` (собственной var пресета). Механика `#if`-гейта та же — правило `resolve`
теперь живёт в пресете `traffic-processing` под своим `#if @resolve_enabled`, а var объявлена
внутри пресета, а не в секции Network. См. [264-traffic-processing-preset.md](264-traffic-processing-preset.md).
**Зависит от:** §120 (декларативный `#if`-шаблон), §246/§253 (Force IPv4 на route-resolve),
пресет FakeIP (§228 + §дополнение HTTPS/SVCB-глушилки).
**Файлы:** `assets/wizard_template.json` (var-декларация + обёртка правила). Кода в
билдере/storage/UI НЕ добавлялось — var подхватывается существующим механизмом
section-vars. (Историческое: после §264 var+правило `resolve` перенесены в пресет
`traffic-processing`.)
**Тип:** новая настройка ядра (bool-var в секции Network / chapter `core`). _Историческое —_
_после §264 var переехала в locked-пресет `traffic-processing` (собственная var пресета)._

---

## 0. Проблема

Глобальное route-правило `{"action": "resolve", "inbound": ["tun-in"], "strategy": ...}`
резолвит домен (отсниффленный) в реальный IP **до** маршрутизации — чтобы работали
GeoIP/IP-CIDR-правила и Force IPv4. Оно включено всегда в vpn-режиме.

Но это правило **несовместимо с FakeIP по замыслу**: FakeIP работает за счёт того, что
реального резолва нет (приложение получает fake-IP, ядро роутит по нему, зная домен из
FakeIP-стора). `resolve inbound:tun-in` форсит настоящий резолв каждого имени через
`route.default_domain_resolver` — в обход DNS-rules, где живёт fakeip-сервер. Если этот
резолвер недоступен (сломан / заблокирован оператором), соединения рвутся с
`router: lookup <domain>: ...connection refused`, **и FakeIP тут бессилен** — это другой
резолвер, параллельный DNS-пути приложений.

Симптом на устройстве (Debug API `/logs/core`): на один домен одновременно
`dns: exchanged A <domain>. ... 198.18.x.x` (FakeIP ОК) **и**
`router: lookup <domain>: ...->10.255.255.1:53: connection refused` (route-resolve в
чёрную дыру).

## 1. Решение

По аналогии с `@sniff_enabled` (§120) — bool-var `resolve_enabled` в секции Network
(chapter `core` = VPN Settings → Core), гейтящий глобальное resolve-правило через `#if`.

> _Историческое (до §264):_ здесь описано исходное размещение var в секции Network.
> После §264 `resolve_enabled` объявлена внутри locked-пресета `traffic-processing`
> (собственная var пресета), а не в секции Network; сам `#if`-гейт правила `resolve`
> не изменился.

- `default_value: "true"` → поведение по умолчанию не меняется (правило остаётся для всех
  существующих конфигов; GeoIP-роутинг и Force IPv4 работают как раньше).
- Выключить → правило выпадает (`#if`-walker дропает array-element при false, как у sniff).
  Тогда при включённом FakeIP route-слой не делает реального резолва → сломанный/операторский
  DNS не при делах, FakeIP реально развязывает.

Механика полностью декларативна: любой var из `template.vars` автоматически попадает в
flat-`vars` с дефолтом из шаблона (`build_config.dart` merge template defaults), а
section-var с `wizard_ui: "edit"` рендерится тумблером через `varsFor('core')` в
`settings_screen.dart`. Нового кода не требуется.

## 2. Изменения в шаблоне

> _Историческое (до §264):_ ниже — исходное размещение var в секции `Network`.
> После §264 var перенесена в пресет `traffic-processing`, а обёрнутое правило `resolve`
> переехало из `config.route.rules` в тело того же пресета (см. 264).

**Var** (секция `Network`, chapter `core`, после `sniff_enabled`):

```json
{
  "name": "resolve_enabled",
  "type": "bool",
  "default_value": "true",
  "wizard_ui": "edit",
  "title": "Resolve destination IP",
  "tooltip": "Resolve the sniffed domain to an IP before routing, so GeoIP and IP rules can match. Turn off when using FakeIP — the fake IP already carries the domain, and a real lookup here would bypass FakeIP and can fail on a broken resolver."
}
```

**Правило** (`config.route.rules`) обёрнуто в `#if @resolve_enabled` (внутренний `#if` на
inbound по `@vpn_mode` сохранён):

```json
{"#if": {"and": ["@resolve_enabled"], "value": {
  "action": "resolve",
  "inbound": [ ...tun-in / mixed-in #if по @vpn_mode... ],
  "strategy": "@resolve_strategy"
}}}
```

## 3. Верификация

e2e на реальном `wizard_template.json` через `#if`-движок (`walk` + `makeResolver`):

| resolve_enabled | route.rules actions |
|---|---|
| default (не задан) | `[sniff, hijack-dns, resolve]` — правило есть |
| `true` | resolve-правило: `inbound:["tun-in"]`, `strategy:"ipv4_only"` |
| `false` | `[sniff, hijack-dns]` — resolve **выпал**, hijack-dns/sniff целы |

426 builder-тестов зелёные.

## 4. Открытое / device-verify

- Проверить на устройстве: FakeIP-пресет + `resolve_enabled = false` → холодный рестарт VPN →
  в `/logs/core` пропадают `router: lookup ...` в `default_domain_resolver`; трафик держится
  на fake-IP. (§246-грабля: только **холодный** Start, не reload; netd-кэш сбрасывается
  рестартом VPN.)
- Убедиться, что GeoIP-direct для RU не разъезжается при выключенном resolve с активным
  FakeIP (ядро роутит fake-IP по домену из FakeIP-стора).
