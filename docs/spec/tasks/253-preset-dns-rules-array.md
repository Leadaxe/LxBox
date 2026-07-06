# §253 — `dns_rules`: массив DNS-правил пресета + возврат Force IPv4 на DNS-слое

> **СТАТУС: РЕАЛИЗОВАНО** (06.07.2026). Прямое следствие §246: вырезав
> deprecated `strategy: ipv4_only` из `dns_rule` ru-direct, мы потеряли
> гарантию «приложение видит только A-записи». RU-домены (yandex.ru) стали
> получать AAAA → приложение соединяется с IPv6 → `geoip-ru` уводит в
> direct-out → мёртвая IPv6-сеть → ERR_CONNECTION_RESET.

## Проблема

1. **Регрессия §246.** Route-слой (`action: resolve, strategy: ipv4_only`)
   работает только для FQDN-целей (ядро: actionResolve только FQDN, §246/§247).
   Приложение, которое резолвит само через системный DNS (все браузеры),
   получает AAAA и соединяется по IP — route-resolve уже не помогает.
   Единственный рычаг для таких приложений — DNS-слой.
2. **Механизм.** Легаси `strategy` в DNS-правиле deprecated (ядро 1.14,
   `OptionLegacyDNSRuleStrategy`) и несовместим с `query_type`/`ip_version`
   в том же конфиге (fatal, см. §246 + healLegacyDnsStrategy). Правильная
   замена — **matcher** `ip_version` + **action** `predefined`.
3. **Шаблон не умел.** Пресет нёс ровно одно DNS-правило
   (`dns_rule: Map`), а для force_ipv4 нужно ДВА (гейт AAAA + маршрут).
   Симметрия с §246, где `rule` → `rules` для route-слоя.

## Семантика ядра (проверено в sing-box-lx v1.14.0-lx.2)

| Факт | Где |
|---|---|
| `metadata.IPVersion` = 4/6 ТОЛЬКО для A/AAAA-запросов; прочие типы (HTTPS/TXT/…) = 0 → не матчатся ни `ip_version: 4`, ни `ip_version: 6` | `dns/router.go:550-555` |
| `predefined` строит authoritative-ответ с заданным `rcode`; `answer` опционален → пустой NOERROR = «домен есть, AAAA нет» — приложение чисто берёт A (без REFUSED/drop/таймаута) | `route/rule/rule_action.go` `RuleActionPredefined.Response` |
| `rcode` парсится и по имени ("NOERROR"), и по числу | `option/dns_record.go` `DNSRCode.UnmarshalJSON` |
| `reject` (default method) отвечает REFUSED и после 50 срабатываний/30с переходит в drop → НЕ подходит для глушения AAAA (ломает fallback у части резолверов) | `docs/configuration/dns/rule_action` |

## Решение

### Шаблон (ru-direct)

```json
"dns_rules": [
  {"#if": {"and": ["@force_ipv4"], "value": {
    "rule_set": ["ru-domains", "ru-services"], "ip_version": 6,
    "action": "predefined", "rcode": "NOERROR"
  }}},
  {"rule_set": ["ru-domains", "ru-services"], "server": "@dns_server", "action": "route"}
]
```

**Порядок критичен — AAAA-гейт ПЕРВЫМ, маршрут вторым и безусловным.**
Обратный порядок (route-правило с `ip_version: 4` первым) оставляет
не-A/AAAA-запросы (HTTPS type 65 и пр.) для RU-доменов без матча → они
уходят в default-резолвер мимо `@dns_server` — поведенческая регрессия.
С гейтом-первым: AAAA перехватывается, всё остальное (A, HTTPS, TXT…)
матчится маршрутом как раньше. И `#if` ровно один.

При `force_ipv4=false` первый элемент **выпадает из массива целиком**
(механика §246: `#if` false без else в обходе List = Dropped-элемент).

### Механизм (симметрия §246 `rule`→`rules`)

- `SelectableRule.dnsRules: List<Map>` — нормализация конструктором:
  `dns_rules` (List, канонический) | `dns_rule` (Map, legacy — fakeip
  остаётся как есть). `touchesDns` → `dnsRules.isNotEmpty || dnsServers.isNotEmpty`.
- `PresetFragments.dnsRules: List<Map>` — substitute гоняется по массиву
  ЦЕЛИКОМ (array-element `#if`, §246). Гейт валидности элемента:
  `server: String` ИЛИ serverless-action (`predefined`/`reject`/`route-options`).
  Плюс dangling-`rule_set` guard как у routing-правил (раньше у dns_rule
  guard'а не было вовсе).
- `custom_rules.dart`: по одному `DnsMirrorEntry` НА ПРАВИЛО (порядок
  шаблона), `dnsRulesByPresetId: Map<String, List<Map>>`;
  `applyCustomDns.extraDnsRulesByPresetId` — тот же тип, legacy-ветка
  `addAll`. Существующий defensive-гейт эмиссии (`body['server']` дожил до
  `dns.servers`) корректен для serverless-правил: `srv is String` = false →
  эмитится.
- Гейты `p.dnsRule != null` → `p.dnsRules.isNotEmpty`
  (build_config `activePresetIdsWithDnsRule`, dns_settings_screen,
  debug-сериализатор `has_dns_rule`).
- UI: `DnsMirrorTile.previewBodies: List<Map>` — превью/диалог показывают
  все правила пресета (rule-источник передаёт `[body]`).

### Что НЕ делаем

- `kind: preset` запись в `dns_options.rules` остаётся ОДНА на пресет —
  тогглит весь блок DNS-правил атомарно (это аспект пресета, не отдельные
  правила). Миграции storage нет.
- Route-слой `resolve + strategy: ipv4_only` (§246) остаётся — `strategy`
  у route-действия `resolve` НЕ deprecated; это второй слой той же защиты
  (FQDN-цели).
- ru-inside не трогаем (нет DNS-аспекта; дыра та же, но добавление DNS-аспекта
  пресету — отдельное продуктовое решение).

## Файлы

| Файл | Изменение |
|---|---|
| `models/parser_config.dart` | `dnsRules` + нормализация + `touchesDns` |
| `services/builder/preset_expand.dart` | `PresetFragments.dnsRules`, array-walk, гейты |
| `services/builder/post_steps/custom_rules.dart` | mirrors per-rule, типы `List` |
| `services/builder/post_steps/dns_rules.dart` | `extraDnsRulesByPresetId: Map<String, List>` |
| `services/builder/build_config.dart` | гейт `dnsRules.isNotEmpty` |
| `screens/dns_settings_screen.dart` (+`widgets/dns_mirror_group_card.dart`, `dns_body_dialogs.dart`) | список тел в превью |
| `screens/custom_rule_edit/tabs/view_tab.dart` | `rules: fragments.dnsRules` |
| `services/debug/serializers/rules.dart` | `has_dns_rule` по списку |
| `assets/wizard_template.json` | ru-direct `dns_rules` (выше) |
| `docs/TEMPLATE.md` | схема `dns_rules` |

## Связанные

- §246 (rules-массив route-слоя; регрессия-повод), §247 (Action & Resolve),
  §249 (ipv4_only-дефолты), §228 (FakeIP, legacy `dns_rule` остаётся),
  §117 (mirror-группа), §033 (bundle-пресеты).
