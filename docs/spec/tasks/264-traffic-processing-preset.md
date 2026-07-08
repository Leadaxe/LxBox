# §264 — Traffic Processing preset (locked/pinned пресет предобработки трафика)

**Статус:** РЕАЛИЗОВАНО, DEVICE-VERIFIED (CPH2411, 09.07.2026) — пресет первым+locked, resolve-vars
только в правиле (ref из internal-секции), FakeIP DNS эмитится, on_change §266 глушит
resolve_enabled (verified: userVars `resolve_enabled=false` при FakeIP on). Все пресеты на
`ui`-объекте, плоский fallback снят.
**Тип:** новый концепт — locked/pinned пресет + перенос базовых route-правил из шаблона в
пресет + объект `ui` в схеме `selectable_rules`. Многослойно (модель + шаблон + билдер +
storage + UI), но ядро НЕ трогаем.
**Зависит от:** §120 (декларативный `#if`-шаблон, section-vars), §125 (паттерн неудаляемого
`vpn-1` — референс для `locked`/`pinned`), §263 (тумблер `resolve_enabled` — переезжает сюда
из секции Network), **§265** (ref-vars — `resolve_strategy` остаётся глобальной, пресет ссылает).
**Заменяет частично:** §263 — `resolve_enabled` переносится из секции Network в этот пресет
(поведение то же, дом другой).

---

## 0. Проблема / зачем

Три движковые настройки предобработки трафика — `sniff_enabled`, `resolve_enabled`,
`resolve_strategy` — сейчас разбросаны в секции Network (VPN Settings → Core), а правила,
которые они гейтят (`sniff`/`hijack-dns`/`resolve` в `config.route.rules`), зашиты в шаблон
отдельно. Пользователь, настраивающий FakeIP, не находит связанные ручки в одном месте, а
`hijack-dns` вообще не настраивается.

Идея владельца: собрать всю предобработку трафика в один именованный пресет **«Traffic
Processing»**, который:
- всегда включён из коробки (`default: true`),
- нельзя выключить/удалить (`locked: true`),
- всегда стоит первым (`pinned: 0`) — критично, т.к. `sniff` обязан быть первым правилом в
  `route.rules` (извлекает домен ДО матчинга роутинга),
- настраивается (5 vars: sniff on/off + timeout, hijack-dns on/off, resolve on/off + strategy).

## 1. Почему порядок критичен (обоснование pinned)

`RuleSetRegistry` (`rule_set_registry.dart:22,76`): `initialRules` (из `config.route.rules`
шаблона) кладутся ПЕРВЫМИ, `addRule` (пресеты, в storage-order) — ПОСЛЕ. Prepend'а нет.
Порядок в массиве = порядок матчинга в sing-box.

Следствие: чтобы правила `sniff`/`hijack-dns`/`resolve` из пресета встали ПЕРВЫМИ, надо
**убрать их из `config.route.rules` шаблона совсем** — тогда пресет Traffic Processing (гарантированно
первый в storage через `pinned: 0`) даёт первые route-правила. `sniff` снова первый. ✅

## 2. Схема: объект `ui` в selectable_rules

Метаданные пресета переезжают из плоских полей в объект `ui`:

```json
{
  "preset_id": "traffic-processing",
  "ui": {
    "label": "Traffic Processing",
    "description": "Core packet handling: sniff the domain, hijack DNS into the tunnel, resolve destinations for routing. Applied first, before all other rules.",
    "default": true,
    "locked": true,
    "pinned": 0
  },
  "vars": [ /* см. §3 */ ],
  "rule": [ /* см. §4 */ ]
}
```

**Поля `ui`:**
| Поле | Тип | Смысл | Дефолт если нет |
|---|---|---|---|
| `label` | string | UI display name | `preset_id` |
| `description` | string | подпись в списке правил | `''` |
| `default` | bool | включён из коробки (= прежний `defaultEnabled`) | `false` |
| `locked` | bool | нельзя выключить/удалить (свич disabled, нет delete) | `false` |
| `pinned` | int? | фикс-позиция в route.rules и в списке; `0` = первый, drag off | `null` (не пиннится) |

**Единообразие (решение владельца 08.07.2026):** ВСЕ пресеты переведены на объект `ui` —
плоские `label`/`description`/`default` из шаблона убраны, fallback в парсере снят.
`SelectableRule.fromJson` читает метаданные ТОЛЬКО из `json['ui']`. Отсутствие `ui` → пустые
дефолты (баг шаблона, ловится тестом). Тестовые `fromJson`-хелперы обновлены на `ui`-форму.

## 3. Vars пресета (5 штук)

`sniff_enabled` / `sniff_timeout` / `hijack_dns_enabled` / `resolve_enabled` — **собственные**
vars пресета (объявляются в нём, значение в `rule.varsValues`). `resolve_strategy` — **ref-var**
(остаётся глобальной, пресет только ссылается — см. §3.1).

| var | type | default | title | примечание |
|---|---|---|---|---|
| `sniff_enabled` | bool | true | Packet sniffing | из Network, собственная |
| `sniff_timeout` | enum | 1s | Sniff timeout | НОВАЯ (был хардкод `timeout:"1s"`); options 100ms/300ms/500ms/1s/3s |
| `hijack_dns_enabled` | bool | true | Hijack DNS | НОВАЯ; тултип-WARNING: off ломает FakeIP и все DNS-rules |
| `resolve_enabled` | bool | true | Resolve destination IP | из Network (§263), собственная |
| `resolve_strategy` | **ref** | — | (из глобали) | `{"ref":"resolve_strategy"}` — см. §3.1 |

Собственные vars редактируются в редакторе правила (preset-var UI, как `ru-direct`).

### 3.1. `resolve_strategy` — ref-var (см. §265)

`resolve_strategy` остаётся ГЛОБАЛЬНОЙ (её читает и `config.dns.strategy` через
`@resolve_strategy`, wizard_template ~L365, и route-resolve пресета). Пресет её только
**ссылает** синтаксисом `{"ref": "resolve_strategy"}` — механизм ref-vars описан отдельной
таской **[§265](265-ref-vars.md)**. Значение живёт в глобальном `userVars`, не в varsValues
пресета; единый источник для DNS-стратегии и route-resolve.

§264 зависит от §265: реализация ref-var — предусловие для этого пресета. Если §265 ещё не
готова — `resolve_strategy` временно объявляется собственной preset-var (дубль-декларация,
работает по flat-namespace, но метаданные дублируются) до внедрения ref.

## 4. Route-правила пресета

Переезжают 1:1 из `config.route.rules` шаблона, каждое под своим `#if`:

```json
"rule": [
  {"#if": {"and": ["@sniff_enabled"], "value": {
    "action": "sniff",
    "inbound": [ {"#if":{"and":[{"@vpn_mode":{"#in":["vpn","vpn_proxy"]}}],"value":"tun-in"}},
                 {"#if":{"and":[{"@vpn_mode":{"#in":["proxy","vpn_proxy"]}}],"value":"mixed-in"}} ],
    "timeout": "@sniff_timeout"
  }}},
  {"#if": {"and": ["@hijack_dns_enabled"], "value": {"protocol": "dns", "action": "hijack-dns"}}},
  {"#if": {"and": ["@resolve_enabled"], "value": {
    "action": "resolve",
    "inbound": [ {"#if":{"and":[{"@vpn_mode":{"#in":["vpn","vpn_proxy"]}}],"value":"tun-in"}},
                 {"#if":{"and":[{"@vpn_mode":{"#in":["proxy","vpn_proxy"]}}],"value":"mixed-in"}} ],
    "strategy": "@resolve_strategy"
  }}}
]
```

`sniff`/`resolve` — в `_kIntermediateActions` (`preset_expand.dart:43`) — нетерминальные,
эмитятся без `outbound`. `hijack-dns`: убедиться, что serverless/интермедиэйт-гейт пропускает
его (action не в списке outbound-требующих). Пресет БЕЗ var:outbound → picker не рисуется
(`hasOutboundAffordance` false, как `fakeip`).

## 5. Механика locked / pinned (референс §125 vpn-1)

**Модель (`SelectableRule` + `CustomRulePreset`):**
- `SelectableRule`: новые геттеры `locked` (bool), `pinned` (int?), + чтение из `ui`-объекта.
- `CustomRulePreset` / хранение: нужен способ понять при рендере, что правило locked/pinned —
  через `presetId` → lookup в `template.selectableRules` (как уже делается для `hasOutboundAffordance`).

**Storage / порядок:**
- Auto-discovery: пресет с `default:true` уже включается (`channels.dart:191`,
  `build_config.dart:724`). pinned:0 → при сборке списка custom rules вставлять первым.
- `saveCustomRules`: не дать сохранить порядок, где pinned-пресет не на позиции 0 (нормализация
  как §125 pinned-секция home_state).

**UI (`custom_rule_tile.dart` + `routing_tabs.dart` RoutingRulesTab):**
- `Switch(onChanged)` (custom_rule_tile.dart:72) → disabled если `locked`.
- delete-колбэк (экран) → скрыть/заблокировать для `locked` (референс `canDelete:
  !channel.isRequired`, routing_screen.dart:357).
- `ReorderableListView.onReorder` (routing_tabs.dart:127) → запретить перемещать pinned-правило
  и вставлять другие выше него (позиция 0 фиксирована).
- drag-handle у pinned-tile — скрыть.

## 6. Миграция

- Удалить из `config.route.rules` шаблона: `sniff`/`hijack-dns`/`resolve` (переезжают в пресет).
- Удалить из секции Network (chapter core) vars: `sniff_enabled`, `resolve_enabled`,
  `resolve_strategy`.
- Существующие userVars-значения (`sniff_enabled` и т.д.) — СОХРАНЯЮТСЯ по имени (см. §3).
  `resolve_strategy` в config.dns тоже читается (`@resolve_strategy` в dns.strategy, wizard_template
  строка ~365) — проверить, что после переноса var всё ещё резолвится (var глобальный, ок).
- Пресет автоматически появляется у всех при следующей сборке (`default:true` + auto-discovery).
- НЕ нужен явный migration-шаг storage: пресет seed'ится auto-discovery, старые var'ы
  подхватываются по имени.

## 7. Места правки (код)

| Файл | Что |
|---|---|
| `assets/wizard_template.json` | новый пресет + удаление базовых route.rules + удаление 3 vars из Network |
| `models/parser_config.dart` | `SelectableRule.fromJson`: читать `ui`-объект (label/description/default/locked/pinned) с fallback на плоские; геттеры `locked`/`pinned` |
| `services/selectable_to_custom.dart:22` | `sr.label` → через новый геттер (совместимо) |
| `services/builder/post_steps/custom_rules.dart:204,226` | `match.label` — совместимо через геттер |
| `services/builder/build_config.dart:724` | `p.defaultEnabled` — совместимо через геттер |
| `services/settings_storage/channels.dart:191` | `p.defaultEnabled` — совместимо |
| `services/debug/serializers/rules.dart:112-114` | `preset.label/description/defaultEnabled` + добавить `locked`/`pinned` в сериализацию (симметрия Debug API) |
| `screens/routing_screen.dart:357+` | canDelete-гейт для locked |
| `screens/routing_screen/widgets/custom_rule_tile.dart:72` | Switch disabled для locked |
| `screens/routing_screen/widgets/routing_tabs.dart:127` | onReorder-гейт для pinned |
| `screens/dns_settings_screen.dart:204,210` | `match.label` — совместимо |
| `services/settings_storage.dart:78-90` | `_configVarKeys` (§113 dirty-трекинг): содержит `resolve_strategy` — после переноса в пресет убрать (иначе мёртвый ключ). Проверить, нет ли там же `sniff_enabled`/`resolve_enabled` (по гайду — нет). Vars пресета dirty-метятся через custom_rules-путь |

## 8. Места правки (документация)

**docs/TEMPLATE.md:**
| Строка | Что |
|---|---|
| L124 | дерево route.rules: убрать `{action:sniff … #if @sniff_enabled}` (переехало в пресет) |
| L126 | убрать `{action:resolve … #if @resolve_enabled}` (§263-строка) — тоже в пресет |
| L222-226 | секция Network vars-список: удалить `sniff_enabled`, `resolve_enabled`, `resolve_strategy` |
| L476 | пример `on_change` ipv6→`@resolve_strategy`: пометить, что var теперь в пресете |
| L540-546 | комментарий про sniff/resolve в config.route.rules — правила теперь из пресета |
| L573-704 | раздел `selectable_rules[]`: описать объект `ui` (label/description/default/locked/pinned) + fallback на плоские; добавить строку traffic-processing в полевую матрицу |
| L611-625 | «магические переменные пресетов»: добавить, что sniff/resolve-vars теперь в traffic-processing |

**docs/spec/tasks/263-resolve-enabled-toggle.md** (весь файл — superseded этой таской):
| Строка | Что |
|---|---|
| L1-11 | статус/шапка: пометить «superseded §264 — resolve_enabled переехал в traffic-processing пресет» + кросс-ссылка |
| L10 | «Тип: bool-var в секции Network» → «переехал в пресет» |
| L35-47 | раздел Решение: var объявляется в пресете, не в Network; механика `#if` та же |
| L49-73 | раздел «Изменения в шаблоне»: пометить как историческое, дать ссылку на §264 |

**docs/STORAGE.md:** проверено — `sniff_enabled`/`resolve_enabled`/`resolve_strategy` в
STORAGE.md НЕ упоминаются (grep пусто). Правок НЕ требуется. Если добавить раздел про
`custom_rules[].varsValues` — упомянуть, что vars пресета живут там, но это опционально.

**docs/ARCHITECTURE.md:** поиск по «порядок route.rules / sniff-первым / базовые правила» —
обновить, что sniff/hijack/resolve поставляются пресетом traffic-processing (первым), а не
жёстким блоком шаблона.

**docs/spec/features/030 custom routing rules/spec.md:** добавить раздел про механику
`locked`/`pinned` пресетов (нельзя выключить/удалить/двигать; pinned:0 = позиция 0 в
route.rules и списке). Референс — §125 vpn-1.

**docs/spec/features/120 template-engine-typed-vars-and-if/spec.md:**
| Строка | Что |
|---|---|
| L383-388 | раздел `sniff_enabled`: var (и resolve_enabled/resolve_strategy) теперь объявлены в traffic-processing пресете, не в Network; `#if`-механика без изменений |

**docs/spec/features/125 configurable-channels** — НЕ правим, только референс (паттерн
locked/pinned vpn-1 берём оттуда).

## 9. Открытые вопросы / верификация

- Тесты: e2e на реальном шаблоне (§246-урок) — route.rules порядок при разных vars, pinned
  всегда [0]; locked-гейты (switch/delete/reorder) виджет-тесты; сериализация Debug API.
- Device-verify: холодный старт, sniff первым, FakeIP-режим (resolve off) работает.
- hijack_dns_enabled: показывать в UI (`wizard_ui:edit`) или скрыть (`hidden`, конфиг только
  через Debug API/backup)? Решено: показывать с WARNING-тултипом.
