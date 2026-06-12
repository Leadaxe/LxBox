# 117 — Опция «DNS» у правила маршрутизации (DNS follows the rule)

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата старта | 2026-06-12 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | features/033 (preset-бандлы — уже бандлят DNS), features/030 (custom rules), features/043 (DNS servers refs), features/061 (DNS rules refs), §118 (per-server detour — даёт каналу detour) |

## Проблема и идея

Field report (4PDA, Pixel 7): юзер хочет, чтобы «нужные заграничные» приложения
и **резолвились** через свой забугорный DNS (adguard на VPS), и сам DNS-запрос
шёл **через тот же VPN-канал** — иначе на DNS-сервере виден реальный IP
провайдера (отсечка от ботов по IP). Сейчас это делается **вручную**: создать
routing-правило, потом отдельно DNS-сервер, потом DNS-правило, вручную свести
матчи — хрупко и неочевидно («рядовой пользователь так глубоко не полезет»).

Идея: у правила маршрутизации — **чекбокс DNS**. Поставил → правило само
регистрирует DNS-правило, которое резолвит **тот же** трафик через выбранный
DNS-сервер. Матч определяется **один раз** (в правиле) и используется в двух
местах — routing и DNS. Это best-practice sing-box (DNS-правила зеркалят
routing) и обобщение того, что **preset-бандлы уже делают** (`applyPresetBundles`
регистрирует rule_set + DNS-сервер + DNS-правило) — здесь то же самое для
пользовательских inline/srs-правил.

**Detour (через какой канал идёт DNS) правило НЕ трогает** — это свойство
самого DNS-сервера (§118 per-server detour). Правило лишь **ссылается** на
сервер; куда тот ходит — решает сервер. Чистое разделение ответственности.

## Контракт ядра (проверено)

- DNS-правило умеет **все** match-поля routing-правила, включая `package_name`
  и `wifi_ssid`/`wifi_bssid` (`option/rule_dns.go`), + `rule_set`. Значит
  app-based и wifi-based правила зеркалятся в DNS.
- `rule_set` (headless) умеет **подмножество**: `domain*`, `ip_cidr`,
  `port*`, `process_name`, `package_name`, `wifi_ssid`/`wifi_bssid`, network.
  **НЕ умеет**: `protocol`, `clash_mode`, `ip_is_private`, geosite/geoip,
  nested rule_set. → отсюда гейт ниже.
- DNS-правило матчит **домен запроса**: rule_set с domain-правилами работает;
  IP-only rule_set (geoip) в DNS не сматчит ничего.

## Модель данных

`CustomRule` — sealed, 3 варианта: `CustomRuleInline` / `CustomRuleSrs` /
`CustomRulePreset`. **Тип/`kind` (`inline|srs`) НЕ меняем** — это user-facing
источник матча. Добавляем **ортогональное поле**:

```dart
// На CustomRuleInline и CustomRuleSrs (Preset уже имеет свой DNS из шаблона):
final RuleDns? dns;   // null = выкл (как сейчас)

class RuleDns {
  final bool enabled;
  final String serverTag;   // ссылка на существующий DNS-сервер (по tag)
}
```

`kind` остаётся `inline|srs`. **Третьего типа (`ruleset`) нет** — форма вывода
(inline route-rule vs inline-rule_set bundle) это **производное эмиттера**, не
персист-тип. Detour в модели правила **не хранится**.

`fromJson`/`toJson`: новый ключ `dns: {enabled, server}`; отсутствие =
backward-compat (выкл).

## Гейт чекбокса (UX)

Чекбокс DNS **серый + disabled** с пометкой, если матч содержит
**не-headless / не-DNS-безопасные** критерии:

| Критерий | DNS-безопасен | в rule_set | в DNS-rule |
|---|---|---|---|
| `domains` (domain/suffix/keyword/regex) | да | да | да |
| `packages` (package_name) | да | да | да |
| `wifi_ssid`/`wifi_bssid` | да | да | да |
| `ports` (port/port_range) | **нет** | да, но в момент DNS-запроса порта назначения нет | блок |
| `protocols` | **нет** | headless не умеет | блок |

- Галка доступна при `domains || packages || wifi` и **отсутствии** `ports`
  **и** `protocols`.
- `ports`/`protocols` выбраны → галка серая, пометка «DNS-follow недоступен:
  порт/протокол известны только после коннекта, в момент DNS-запроса их нет».
- `wifi` → пометка «требует разрешение геолокации» (как у routing-правил по
  wifi, §051/§1.7.3 — без геолокации SSID не отдаётся, правило молча не
  сматчится).

## Эмиссия (билд)

Расширяем `applyAllCustomRules` (`post_steps/custom_rules.dart`) — кейсы
`CustomRuleInline()` / `CustomRuleSrs()` при `dns?.enabled == true`. Машинерия
уже есть: `RuleSetRegistry` (уникальность тегов, `tryRegisterRuleSet`),
`extraDnsServers`/`extraDnsRules` → `applyCustomDns`.

**inline + dns:**
1. inline rule_set `rs-<ruleId>` из DNS-безопасного матча (domains/packages/wifi)
   → `registry.addRuleSet`.
2. route-rule = `{ rule_set: "rs-<ruleId>", outbound: <канал правила> }` (вместо
   inline-матча). Поведение routing идентично (rule_set-матч = тот же набор).
3. DNS-rule = `{ rule_set: "rs-<ruleId>", server: <serverTag> }` → в `extraDnsRules`.

**srs + dns:**
1. rule_set **не генерим** — ссылаемся на **существующий `.srs`-тег**.
2. route-rule как сейчас (srs-ref + доп-фильтры).
3. DNS-rule = `{ rule_set: "<srs-tag>", <DNS-безопасные доп-фильтры>, server: <serverTag> }`.
4. **Серая пометка в UI**: «работает, только если в rule-set есть домены»
   (содержимое `.srs` приложение не парсит — IP-only лист молча не сматчит).

Во всех случаях: убедиться, что `<serverTag>` присутствует в `dns.servers`
(он уже добавлен юзером в DNS-настройках; если ссылается на удалённый — см.
edge). **Detour сервера правило не трогает.**

## Locked decisions

1. Модель: 2 типа (`inline|srs`) без изменений; `dns` — ортогональное поле.
   Третьего `ruleset`-типа нет (форма вывода — производное эмиттера).
2. **No split**: при `dns` вкл **весь** (DNS-безопасный) матч уезжает в один
   rule_set, шарится route+DNS. Не «часть inline, часть rule_set».
3. Detour — свойство сервера (§118), не правила. Правило только ссылается.
4. Выбор DNS-сервера = из **списка существующих** (по tag), не ввод адреса
   в правиле.
5. SRS+DNS разрешён + серая пометка (содержимое `.srs` не валидируем).
6. Рейнейм вариантов модели (`CustomRuleInline`→…) — **не сюда**, отдельной
   косметической таской.

## Риски и edge cases

- **Канал DNS не пойдёт через туннель без §118**: правило ссылается на сервер,
  а через какой канал сервер ходит — задаёт его `detour` (§118 per-server
  detour). Без §118 у выбранного сервера detour не настроить из UI → DNS
  пойдёт по дефолту сервера. То есть §117 даёт удобство (авто-DNS-rule), а
  «через VPN-канал» включает §118. **Зависимость зафиксировать в релиз-нотах.**
- Выбранный сервер удалён из DNS-настроек → правило с висящим `serverTag`:
  билд пропускает DNS-rule + warning; UI — broken-индикатор у правила
  (как broken-preset, §033).
- Тег `rs-<ruleId>` уникален (RuleSetRegistry авто-суффиксит, но id правила
  стабилен → коллизий нет).
- Ордеринг DNS-правил: пользовательские DNS-rule вставляются до `dns.final`,
  в порядке правил (детерминированно).
- DNS-follow усиливает стартовую гонку «нет трафика, пока не перезапустишь»
  (DNS теперь ждёт готовности канала) — отдельный разбор (репорт пункт 2,
  Pixel 7), но проектировать с оглядкой.

## UI

- В редакторе правила (`custom_rule_edit`) — секция/строка **DNS**:
  - чекбокс (серый+пометка при ports/protocols);
  - при вкл — дропдаун «DNS server» из существующих DNS-серверов (tag + label);
  - под чекбоксом — контекстные пометки (wifi-геолокация; для srs —
    «только если в rule-set есть домены»).
- Источник списка серверов — те же resolved DNS servers, что в DnsSettingsScreen.

## Верификация

- Unit: эмиссия inline+dns → rule_set + route-rule(ref) + DNS-rule(ref→server);
  srs+dns → DNS-rule на существующий srs-тег; гейт (ports/protocols → нет dns);
  удалённый server → skip+warning; backward-compat (нет `dns` → старое поведение).
- `flutter analyze` чистый, полный `flutter test` зелёный.
- `sing-box check` на сгенерированном конфиге (inline+dns, srs+dns).
- Девайс-смок: app-based правило + DNS на свой сервер → запросы тех приложений
  резолвятся выбранным сервером; (с §118) уходят через канал — на DNS виден IP
  VPS.

## Нерешённое / follow-up

- **§118 per-server detour** — параллельная фича: detour-селектор у DNS-сервера
  (Direct/каналы). Именно она делает «DNS через канал». §117 без неё = авто-
  DNS-rule на сервер с его дефолтным detour.
- Рейнейм вариантов модели — косметическая таска.
- Стартовая гонка «нет трафика» (репорт п.2) — отдельная диагностика.
