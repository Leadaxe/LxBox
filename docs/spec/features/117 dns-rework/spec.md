# 117 — Комплексная переработка DNS

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата старта | 2026-06-12 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | features/033 (preset-бандлы — уже бандлят DNS через vars/`@outbound`), features/043 (DNS servers refs), features/061 (DNS rules refs), features/030 (custom rules) |

## Зачем

Field report (4PDA, Pixel 7): пользователю нужно, чтобы DNS-запросы «нужных»
приложений шли **через VPN-канал** (иначе на его забугорном DNS виден реальный
IP провайдера), а резолвились его сервером. Сейчас это собирается вручную из
трёх кусков (routing-правило + DNS-сервер + DNS-правило), без UI-управления
detour'ом у сервера. Цель — сделать DNS управляемым и связным:

- у каждого DNS-сервера — **переменные** (через какой канал ходит = `detour`,
  какой IP/профиль), редактируемые в UI;
- у правила маршрутизации — **опция DNS**: само регистрирует DNS-правило на
  выбранный сервер (не писать руками).

## Состав — 3 задачи (порядок выполнения)

| # | Задача | Суть | Очередь |
|---|--------|------|---------|
| 1 | Формат DNS-секции шаблона | `{description, enabled, vars, server}` с `@placeholders` | первая |
| 2 | Переменные у DNS-серверов (UI + build) | resolve `{vars,server}`, подстановка, var-редакторы, `outbound`-пикер | вторая |
| 3 | Опция DNS у правила | правило → rule_set + DNS-rule на сервер | **последняя** |

Задачи 1+2 неразделимы при шиппинге (формат без обработки ломает DNS — см.
ниже). Задача 3 — поверх 1+2.

## Контракт ядра (проверено по sing-box-lx)

- DNS-сервер: `detour string` (`option/dns.go:359`) — через какой outbound идёт.
- DNS-правило умеет **все** match-поля routing-правила, вкл. `package_name`,
  `wifi_ssid`/`wifi_bssid`, `rule_set` (`option/rule_dns.go`).
- headless rule_set — **подмножество** обычного правила: `domain*`, `ip_cidr`,
  `port*`, `process_name`, `package_name`, `wifi_*`. **НЕ умеет** `protocol`,
  `clash_mode`, `ip_is_private`, geosite/geoip, nested rule_set.
- DNS-правило матчит **домен запроса** (IP-only rule_set в DNS не сматчит).

---

## Задача 1 — формат секции DNS в шаблоне

Каждый DNS-сервер в `app/assets/wizard_template.json` (`dns_options.servers`)
переходит на обёртку:

```jsonc
{
  "description": "Google DNS (direct)", "enabled": true,
  "vars": [
    {"name": "outbound", "type": "outbound", "default_value": "direct-out",
     "title": "Outbound", "tooltip": "Which channel carries DNS queries to this server"},
    {"name": "dns_ip", "type": "enum", "default_value": "8.8.8.8", "title": "UDP server IP",
     "options": [ {"title": "8.8.8.8 · Primary v4", "value": "8.8.8.8"}, … ]}
  ],
  "server": {
    "type": "udp", "tag": "google_udp", "server_port": 53,
    "server": "@dns_ip", "detour": "@outbound"
  }
}
```

- `vars` — те же определения, что у preset-vars (§033): `outbound`/`enum`/…
- `server` — тело sing-box DNS-сервера с `@placeholder`'ами.
- `detour: "@outbound"`, default `direct-out` → по умолчанию direct, юзер
  выбирает канал per-server.
- Консолидация: Quad9 + AdGuard + AdGuard Family → один «Safe DNS» с
  `safe_profile`-enum; `dns_ip` enum несёт IPv4/IPv6 варианты.
- `local_dns_resolver` — та же обёртка без `vars`.
- **Доменные серверы** (адрес = hostname, напр. Safe DNS adguard-профиль):
  `domain_resolver: "@dom_resolver"` + var `{name: dom_resolver,
  type: dns_servers, default_value: "google_udp"}` (решение №4) — чтобы было
  чем резолвить имя самого DNS-сервера.

**Эталон формата уже сформирован** в рабочем дереве (правка
`wizard_template.json`) — он и есть reference этой задачи.

⚠️ **Не шиппится в одиночку.** `tag` уехал в `server.tag`, а `resolveDnsServers*`
индексирует по top-level `tag` → все серверы (включая local) **молча
отвалятся**, у юзера DNS станет пустым. Поэтому задача 1 едет вместе с задачей 2.

Done: формат в шаблоне, удалённые теги нигде не реферятся (проверено:
`quad9_dot`/`adguard_dot`/`adguard_family`/`google_doh_vpn` — 0 ссылок).

---

## Задача 2 — переменные у DNS-серверов (UI + build)

Научить pipeline и UI новой обёртке.

**Build (`post_steps/dns_servers.dart`, `resolveDnsServers*`):**
- читать `{description, enabled, vars?, server}`: tag/body брать из `server`;
- **подставлять `vars`** в body значениями пользователя (или `default_value`) —
  для standalone-серверов (сейчас substitution только preset/wizard-scoped);
- **стирать `detour`, когда он `direct-out`** (логика уже есть в
  `preset_expand`: «detour == direct-out → удаляем ключ»);
- миграция: старые plain-body записи в сторадже → новый shape (или сосуществуют).

**Storage:** персист выбранных значений vars per-server (сейчас inline-сервер
хранит body, не vars+values). Расширить kind-ref запись.

**UI (`DnsSettingsScreen`):**
- рендерить `TemplateVarListView` для vars сервера (enum/secret/bool уже умеет);
- **новый код: `case 'outbound'` в [`template_var_list.dart`](../../../app/lib/widgets/template_var_list.dart)** —
  пикер канала (Direct + теги outbound'ов из текущего конфига). Сейчас
  `type:outbound` падает в `default` (текстовое поле), пикера нет. Генерик —
  после него `type:outbound` работает везде.

**Это и есть per-server detour** — и решение проблемы №1 репортёра: добавил
adguard как DNS-сервер, у его `outbound`-var выбрал VPN-канал → `detour`=канал →
DNS уходит через туннель, виден IP VPS.

Done: новый шаблон (задача 1) резолвится корректно; юзер меняет outbound/IP у
сервера в UI; `direct-out` не попадает в конфиг; `sing-box check` зелёный.

---

## Задача 3 — опция DNS у правила (DNS follows the rule) [последняя]

Удобство: правило само регистрирует DNS-правило на выбранный сервер, чтобы не
писать DNS-rule руками. Обобщение того, что preset-бандлы (`applyPresetBundles`,
§033) уже делают через `RuleSetRegistry` + `extraDns*`.

**Модель.** `CustomRule` sealed (Inline/Srs/Preset). `kind: inline|srs` **не
меняем** (user-facing источник матча). Добавляем **ортогональное** поле:
```dart
final RuleDns? dns;            // null = выкл
class RuleDns { final bool enabled; final String serverTag; }
```
Третьего `ruleset`-типа нет — форма вывода это производное эмиттера.

**Гейт чекбокса.** Доступен при `domains || packages || wifi`; **серый при
`ports || protocols`** (headless их не выразит; порт/протокол неизвестны в
момент DNS-запроса).

**Эмиссия** (расширить `applyAllCustomRules`, кейсы Inline/Srs при `dns.enabled`):
- **inline+dns**: inline rule_set `rs-<id>` из DNS-безопасного матча → route-rule
  `{rule_set: rs-<id>, outbound}` + DNS-rule `{rule_set: rs-<id>, server: <tag>}`.
  **No split**: весь (DNS-безопасный) матч уезжает в rule_set, шарится route+DNS.
- **srs+dns**: rule_set не генерим — оба места ссылаются на существующий
  `.srs`-тег; DNS-rule `{rule_set: <srs>, <DNS-безопасные доп-фильтры>, server}`.
  **Серая пометка**: «работает, только если в rule-set есть домены» (содержимое
  `.srs` не парсим → IP-only лист молча не сматчит).

**UI:** в редакторе правила — строка DNS: чекбокс (серый+пометка при ports/
protocols) + дропдаун «DNS server» из существующих серверов.

**Граница:** правило только **ссылается** на сервер по tag. Detour сервера
(через какой канал) — зона задачи 1/2, правило его не трогает.

**Ордеринг** (решение №6): DNS-mirror правил эмитятся в порядке routing-правил
(пресет+rules, одним списком) — двигаешь routing-правило, его DNS-mirror едет
следом; группа атомарна. Standalone §061-DNS-правила юзер двигает только выше
или ниже mirror-группы целиком, не внутрь.

Done: inline+dns / srs+dns эмитятся корректно; гейт; удалённый сервер →
DNS **тихо** пропадает (без warning); backward-compat (нет `dns` → старое
поведение).

---

## Жизненный цикл DNS-сервера (баг + правило)

**Существующий баг (до §117):** пресет регистрирует DNS-сервер (напр.
`yandex_udp`) + DNS-правило на него. Сервер при этом появляется в UISettings с
**enabled-тогглом** (`resolveDnsServersList` авто-дискаверит preset-серверы как
`{enabled:true, kind:preset}`). Выключаешь сервер → `resolveDnsServersBodies:9`
выкидывает его из `dns.servers`, но DNS-правило пресета (`extraDnsRules`)
ссылается в пустоту → **битый конфиг**.

**Правило-фикс (сквозное):** DNS-сервер, на который ссылается **активный**
пресет или правило (задача 3), — **управляемый, не выключается/не удаляется
независимо**:
- UI: locked-индикатор + кто ссылается («used by <пресет/правило>»); тоггл
  enabled заблокирован; delete заблокирован.
- Build: referenced-сервер **force-include** в `dns.servers` независимо от
  `enabled` (защита от орфана, defense-in-depth).
- Снятие зависимости (пресет/правило выключен/удалён) → сервер снова
  самостоятелен, тоггл/delete доступны.
- Касается **обоих**: preset-registered серверов (текущий баг) и standalone-
  серверов, выбранных правилом задачи 3.

Это можно вычистить и сейчас (preset-кейс — pre-existing), но логичнее в задаче
2, где живёт lifecycle/enabled-семантика DNS-серверов.

## Locked decisions (сквозные)

1. detour — свойство **сервера** (задачи 1/2), не правила. Правило ссылается.
2. Выбор DNS-сервера у правила — из **списка существующих** (по tag), не ввод
   адреса.
3. Модель правил: 2 типа (`inline|srs`) без изменений; `dns` — ортогональное
   поле. Третьего типа нет.
4. **No split** в задаче 3.
5. SRS+DNS разрешён + серая пометка.
6. detour = «var типа outbound», не bespoke-селектор (генерик через vars).
7. DNS-сервер, реферимый активным пресетом/правилом, не выключается/не
   удаляется независимо (см. «Жизненный цикл DNS-сервера»).

## Решения открытых вопросов

1. **Миграция — НЕ нужна, обратной совместимости не требуется.** kind-ref +
   orphan-cleanup (`dns_servers.dart:57,61` — removed/renamed теги выпадают
   сами) + `default_value` vars покрывают существующее состояние органически.
   Единственное требование: resolve (задача 2) читает tag из `server.tag` и
   применяет дефолты vars. Inline-серверы юзера (свой body) не трогаются;
   удалённые теги (`quad9_dot`…) орфан-чистятся.
2. **outbound-пикер**: источник = **только активные каналы**. Выбранный канал
   исчез / не выбран / `direct-out` → ключ `detour` **просто не пишется**
   (НЕ `direct`, а отсутствие ключа). «Нет detour» = и дефолт, и fallback.
3. **Исчезнувший реф правило→сервер — тихо, без ошибок**: правило ссылается на
   DNS-сервер, которого больше нет → DNS-rule правила **тихо не эмитится**
   (без warning / broken-индикатора). *(Переопределяет ранний edge
   «skip+warning».)* — Только про реф правила; пропавший канал у `detour`
   сервера — это решение №2 (ключ detour не пишется, сервер живёт), к №3
   отношения не имеет.
4. **Доменные серверы**: `domain_resolver` — **var** (`type: dns_servers` /
   `@dns_server`), default `google_udp`. Для серверов с hostname-адресом
   (Safe DNS adguard-профиль и т.п.).
5. **Задача 3, гейт**: outbound правила DNS-галку **не ограничивает** —
   доступна при любом outbound (вкл. direct/block). Гейт только
   `ports || protocols` (headless).
6. **Ордеринг DNS-правил**:
   - **mirror-группа** (DNS-rules из routing-правил пресета+rules) — порядок
     **строго = порядку routing-правил**, независимо не двигается; подвинул
     routing-правило → его DNS-mirror поехал.
   - **standalone DNS-правила** (§061, редактируются в DNS-настройках) — юзер
     двигает свободно, но относительно mirror-группы только **выше или ниже
     неё целиком**, не внутрь (группа атомарна).

## Граница ответственности

- **Wifi-разрешения / геолокация** — машинерия wifi-правил (§051), не §117.
- **Рейнейм вариантов модели** (`CustomRuleInline`→…) — отдельная косметическая
  таска, не сюда.
- **Стартовая гонка «нет трафика»** (репорт п.2, Pixel 7) — отдельная
  диагностика, не §117.

## Риски и edge cases

- Задача 1 без задачи 2 ломает DNS (tag в `server.tag`) — шиппить вместе.
- «Safe DNS» с доменным профилем (adguard) → адрес сервера это hostname →
  нужен `domain_resolver`/bootstrap; в шаблоне у `safe_dns_dot` его нет — учесть.
- DNS-сервер по IP — петли нет; по домену + detour=канал → bootstrap через
  канал, спроектировать.
- Выбранный сервер исчез → правило с висящим `serverTag`: DNS-rule **тихо**
  не эмитится, без warning (решение №3). NB: пока сервер реферится активным
  правилом, он не удаляется (locked #7) — кейс защитный.
- Теги `rs-<ruleId>`/`dns-<…>` уникальны (RuleSetRegistry авто-суффиксит).

## Верификация

- Unit: resolve нового формата (vars подставлены, direct-out стёрт, tag из
  server); эмиссия rule+dns (inline/srs); гейт; backward-compat.
- `flutter analyze` чистый, полный `flutter test` зелёный.
- `sing-box check` на собранном конфиге (server-vars, rule+dns inline, rule+dns srs).
- Девайс-смок: сервер с outbound=VPN → DNS через канал (виден IP VPS); правило с
  DNS → его трафик резолвится выбранным сервером.
