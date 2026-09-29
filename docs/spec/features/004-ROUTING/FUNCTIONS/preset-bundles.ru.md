[English](preset-bundles.md) · [Русский](preset-bundles.ru.md)

# Пресеты-бандлы — готовые правила маршрутизации из шаблона приложения

Пресет-бандл добавляет готовые правила, rule set и DNS-части из шаблона приложения — например, Ru
internet segment, BitTorrent или блокировку рекламы — и настраивается несколькими переменными.

| Поле | Значение |
|------|----------|
| Фича | [004-ROUTING](../FEATURE.ru.md) |
| Обещания | P2 P13 P14 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Даёт готовые правила из шаблона приложения: каталог на табе **Presets**,
кнопка «Add to Rules» (после добавления — «In Rules»). Пресет в списке
правил — ссылка на шаблон плюс значения его переменных: обновилось
приложение — обновилось поведение у всех. Пресет может нести сразу
rule_set'ы, несколько правил маршрута, DNS-серверы и DNS-правила.

## Параметры

| Пресет | Умолч. | Номер | Что делает | Переменные |
|---|---|---|---|---|
| Traffic Processing | вкл, закреплён | 0 | `sniff`, `hijack-dns` для `protocol: dns`, `resolve` | Packet sniffing, Sniff timeout, Hijack DNS, Resolve destination IP¹, Resolve strategy¹ |
| Tailscale networks | вкл | 945 | на каждый узел Tailscale: `preferred_by` → узел, резолв его DNS | DNS |
| Private IPs | выкл | 950 | `ip_is_private` | Outbound (`direct-out`) |
| Block Ads | выкл | 960 | внешний `ads-all` → reject | — |
| Google push (FCM) | выкл | 970 | хосты FCM и порты 5228–5230 | Outbound, Limit to Google Play Services |
| BitTorrent | вкл | 980 | `protocol: bittorrent` | Outbound (`direct-out`) |
| VoWiFi (carrier calling) | вкл | 990 | `pub.3gppnetwork.org`, UDP 500/4500 | Outbound, Match IKE ports |
| Russia-only services | выкл | 1110 | внешний список «доступно только из РФ» | Outbound, Force IPv4 |
| Ru internet segment | вкл | 1120 | ru-TLD, сервисы, GeoIP-RU, российские приложения | Outbound, DNS, UDP server IP, GeoIP IP-range fallback, Russian apps by package, Force IPv4 |
| FakeIP | выкл | 1130 | только DNS (см. 005) | DNS, Block HTTPS records |
| Unknown traffic | выкл | 1150 | трафик без приложения-владельца | outbound (`reject`) |

¹ глобальная переменная: общая для всего приложения, а не для правила.

Виды переменных в редакторе пресета: переключатель, выбор из списка,
текст/число, цель (Направление), DNS-сервер. Скрытые переменные шаблона не
показываются.

## Входы / Выходы

**Входы:** `selectable_rules` шаблона; значения переменных; глобальные
переменные; кэш внешних наборов; узлы (для Tailscale).
**Выходы:** фрагменты в `route.rule_set`, `route.rules` (в позиции пресета),
DNS-часть — в [005-DNS](../../005-DNS/FEATURE.ru.md).

## Правила и инварианты

- Хранится только id пресета и значения, отличные от умолчания; выбор
  умолчания снимает ключ. Имя в редакторе только для чтения — живое название
  из шаблона текущей локали.
- Цель пресета, выбранная пикером, заменяет решение шаблона целиком:
  reject ↔ Направление ↔ `direct`; промежуточные `resolve`/`sniff` не
  затрагиваются. `reject` всегда становится `action: reject`.
- Фрагмент, выключенный переменной (`#if`/`#enable`), не эмитится; правило,
  у которого после подстановки не осталось ни цели, ни условий, выпадает с
  предупреждением.
- Пресет, которого нет в шаблоне: пропуск сборкой, в списке «Preset not
  found — tap to fix».
- Одинаковые rule_set двух пресетов регистрируются один раз; разные с одним
  тегом — первый побеждает, предупреждение.
- **Traffic Processing:** засевается всегда, если его нет; его свич
  недоступен, удаление скрыто, drag запрещён. Выключение Packet sniffing
  отключает матч по протоколу (и по домену без FakeIP); выключение Hijack
  DNS отключает FakeIP и все DNS-правила — предупреждение в подсказке.
- Засев на чистой установке: пресеты с `default: true`, один раз. Пресет,
  ставший дефолтным позже (Tailscale networks), добавляется существующим
  пользователям один раз.
- Копии одного пресета при загрузке схлопываются — остаётся последняя.
- Включение FakeIP переключает «Resolve destination IP» — см. 005.
- Строка пресета в списке: подпись из изменённых переменных, чип «DNS», если
  пресет трогает DNS; пикер цели — только у пресетов с целью.

## Границы

- Язык шаблона (`#if`, `#enable`, `for_each`, ref-переменные) —
  [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.ru.md).
- Пресеты не переносятся обменом правилами — [rule-transfer](rule-transfer.ru.md).
- Своих пресетов пользователь не создаёт.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [033F](../../../tasks/033F-preset-bundles/spec.md) | Active (v1.5.0) | Пресет как самодостаточный бандл с переменными, ссылка вместо копии |
| 2 | [010](../../../tasks/010-preset-bundles.md) | ✅ Реализовано | Первая реализация бандлов, `ru-direct` |
| 3 | [067](../../../tasks/067-selectable-rule-legacy-cleanup.md) | Released v1.9.0 | У каждого пресета обязателен `preset_id` |
| 4 | [121](../../../tasks/121-preset-routing-king-dns-orphans.md) | Released v2.1.0 | Выключенный пресет не оставляет DNS-хвостов |
| 5 | [162](../../../tasks/162-block-unknown-default-reject-outbound.md) | Done | Умолчание `reject` → `action: reject` |
| 6 | [228](../../../tasks/228-fakeip-preset.md) | реализация | Пресет FakeIP, чистка outbound-переменных |
| 7 | [246](../../../tasks/246-preset-rule-array.md) | — | Пресет даёт несколько правил: `resolve ipv4_only` + route |
| 8 | [264](../../../tasks/264-traffic-processing-preset.md) | device-verified | Traffic Processing: первый, закреплённый |
| 9 | [265](../../../tasks/265-ref-vars.md) | device-verified | Переменные-ссылки на глобальные значения |
| 10 | [266](../../../tasks/266-preset-on-change.md) | device-verified | Реакция пресета на изменение (FakeIP → resolve) |
| 11 | [364](../../../tasks/364-fcm-push-bypass-preset.md) | реализовано | Пресет Google push (FCM) |
| 12 | [371](../../../tasks/371-vowifi-direct.md) | реализовано, device-pending | Пресет VoWiFi, суффикс ePDG в Ru internet segment |
| 13 | [441](../../../tasks/441-template-preset-vars-in-record.md) | Released v2.24.0 | Умолчания переменных не хранятся |
| 14 | [571](../../../tasks/571-rule-conditions-allowlist.md) | Done | Правило без условий выпадает |
| 15 | [578](../../../tasks/578-tailscale-preset-template-for-each.md) | Spec, реализация запущена | Пресет Tailscale: правило на каждый узел, поздний засев |
