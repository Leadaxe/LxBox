# §121 — Routing-тоггл = король: DNS-хвосты при выключении пресета

**Статус:** Released (v2.1.0)
**Тип:** bug-fix (3-слойный)
**Связано:** §033 (independent DNS-aspect), §043 (DNS servers refs), §061 (DNS rules refs), §117 (server lifecycle / locked)

---

## 1. Симптом (баг-репорт пользователя)

> «Yandex Safe DoT стал серым. Если ставлю его основным резольвером — пишет
> "не найден" при запуске. Если ставлю local — снизу жёлтое сообщение
> "переключите на Cloudflare UDP".»

Yandex-резольверы (`yandex_udp/doh/dot`) — не самостоятельные template-серверы, а
часть пресета **`ru-direct`** (`wizard_template.json`, preset block). Они
появляются только пока пресет активен.

Корневая жалоба шире симптома: **при выключении пресета остаётся
рассинхронизированный «хвост»** —

1. **DNS-серверы пресета исчезают** (orphan-cleanup серверов работает);
2. **DNS-правило пресета — НЕ исчезает** (orphan-cleanup правил не срабатывает);
3. **`dns.final` / `default_domain_resolver` / per-rule resolver**, если
   ссылались на исчезнувший сервер, **остаются с битым tag'ом** → sing-box
   реджектит config при старте → «server not found» («не найден при запуске»).

---

## 2. Решение (продуктовое, утверждено)

**ROUTING-тоггл пресета (`CustomRulePreset.enabled`) — король.**

`cr.enabled == false` ⇒ пресет мёртв целиком, как будто его нет в конфиге:
- не порождает DNS-серверы,
- не порождает DNS-правила,
- не создаёт server-lock'и (`dnsMirror`).

Это **сознательно сужает** инвариант §033 «DNS-аспект пресета независим от
routing». Уточнённая модель:

> Независимый DNS-флаг пресета (`dns_options.rules[kind=preset].enabled`)
> действует **только пока `cr.enabled == true`**. Выключенный routing-тоггл
> подчиняет (gate'ит) DNS-аспект.

Истинность: `dnsEnabled := cr.enabled && (isPresetDnsEnabled[pid] ?? false)`.

---

## 3. Root-cause карта (что фиксим)

| # | Слой | Файл:строка | Сейчас | Фикс |
|---|------|-------------|--------|------|
| A | build: emit серверов/правил/mirror | `custom_rules.dart:105` | `dnsEnabled = isPresetDnsEnabled[pid] ?? false` (routing-флаг не учтён) | `dnsEnabled = cr.enabled && (isPresetDnsEnabled[pid] ?? false)` |
| B | build: auto-discovery/orphan правил | `build_config.dart:226` | `activePresetIdsWithDnsRule` без `cr.enabled` | `+ cr.enabled` в comprehension |
| C | UI: сбор серверов/правил пресета | `dns_settings_screen.dart:170-197` | `expandPreset` без `cr.enabled` → presetServersWithLabel / presetRulesByPresetId / activePresetIdsWithDnsRule набирают выключенный пресет | `if (!cr.enabled) continue;` перед expand |
| D | resolver сброс | `dns_settings_screen.dart:_load` + `_toggleServerEnabled` | битый tag не сбрасывается | автосброс на template default если tag ∉ enabledServerTags |
| E | валидатор | `validator.dart` | `dns.final` / `default_domain_resolver` не проверяются | `DanglingDnsServerRef` (fatal) |

Серверный orphan-cleanup (`dns_servers.dart:113`, через `presetServersByTag`)
уже корректен — после C/A он получает пустой набор серверов для выключенного
пресета и чистит их симметрично правилам.

---

## 4. Слой D — автосброс resolver на дефолт

Дефолты из `wizard_template.json` (vars):
- `dns_final` → `local_dns_resolver`
- `dns_default_domain_resolver` → `cloudflare_udp`

В `_load`, после `resolveDnsServersList` / вычисления `_enabledServerTags`:
- если `_dnsFinal` непустой и ∉ `_enabledServerTags` → `_dnsFinal = 'local_dns_resolver'`, mark dirty;
- если `_defaultResolver` непустой и ∉ `_enabledServerTags` → `_defaultResolver = 'cloudflare_udp'`, mark dirty.

Per-rule resolver (`cr.dns.serverTag`) — §117 уже держит сервер locked, пока
правило активно (`_ruleRefsByTag`). При выключении пресета правило-источник
тоже уходит (слой C), lock снимается, сервер чистится. Отдельный сброс
`serverTag` не нужен — мёртвая ссылка живёт только внутри неактивного правила.

---

## 5. Слой E — валидатор

`validateConfig` (validator.dart): собрать `dnsServerTags` из
`config.dns.servers[].tag`; проверить:
- `config.dns.final` (если непустой) ∈ dnsServerTags;
- `config.route.default_domain_resolver` (если непустой) ∈ dnsServerTags.

Иначе → `DanglingDnsServerRef(field, tag)` (fatal). Новый sealed-case в
`models/validation.dart`. Это второй рубеж: даже если слой D пропустит
edge-case, build не уйдёт в sing-box с битым ref → пользователь увидит
понятную ошибку конфига вместо «server not found» от ядра.

---

## 5a. Отменённый инвариант §033

§033 разрешал **DNS-only пресет**: routing-тоггл off (`cr.enabled=false`) +
DNS-аспект on → DNS-фрагменты всё равно эмитились. §121 это **отменяет** —
routing-тоггл король. Затронутый тест
`apply_preset_bundles_test.dart` («dns active, route disabled → DNS fragments»)
переписан под новую семантику: выключенный routing ⇒ ни routing rule, ни
rule_set, ни DNS-фрагменты, ни mirror.

## 6. Edge-cases / проверки

- **Пресет удалён свайпом** (нет в customRules) — уже работал, регрессий нет.
- **`cr.enabled=false`, DNS-аспект `enabled=true`** — теперь DNS не эмитится
  (король). При обратном включении routing — DNS-аспект восстанавливается из
  своего сохранённого флага (storage-запись не удаляется, только не эмитится).
- **`local_dns_resolver` всегда есть** в template → автосброс `dns_final`
  никогда не создаёт новый битый ref.
- **`cloudflare_udp`** — template-сервер с `enabled:true` по умолчанию; если
  юзер его выключил — он всё равно в каталоге (template tag не исчезает),
  значит валиден как resolver-target.

---

## 7. Тесты

- builder: orphan-cleanup правил при `cr.enabled=false` (правило выкидывается);
- builder: серверы пресета не эмитятся при `cr.enabled=false`;
- builder: `dnsEnabled` gate — DNS-аспект подавлен выключенным routing;
- widget/unit: автосброс `_dnsFinal`/`_defaultResolver` при исчезновении tag;
- validator: `DanglingDnsServerRef` на битый `dns.final` / `default_domain_resolver`.
