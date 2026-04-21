# 033 — Preset bundles (parametrized self-contained rules)

| Поле | Значение |
|------|----------|
| Статус | **Active** (landing в v1.5.0) |
| Дата | 2026-04-21 |
| Зависимости | [`030 custom routing rules`](../030%20custom%20routing%20rules/spec.md), [`014 dns settings`](../014%20dns%20settings/spec.md) |
| Поглощает | "inline rule_set в `route.rule_set`" для selectable-пресетов — теперь каждый пресет self-contained |

---

## Цель

Селектейбл-пресет из `wizard_template.json` становится **self-contained bundle**: он несёт свой rule_set, DNS-серверы, DNS-правило, routing-правило и типизированные **переменные** (`@out`, `@dns_server`, ...), значения которых юзер задаёт в UI.

`CustomRule` третьего типа — `preset` — становится **тонкой ссылкой** на такой пресет: `{presetId, varsValues}`. Никаких копий match-полей, никакого «ручного» конфига в правиле — только id пресета и значения его переменных.

### Зачем

1. **Единый источник правды.** Хотим расширить список русских TLD или добавить DNS-сервер — правим шаблон, следующий билд у всех пользователей подтягивает новый контент.
2. **Динамический контекст.** Пресет может использовать свой DNS только тогда, когда он активен. Отключил «Russian domains direct» — `yandex_doh` уходит из конфига вместе с ним.
3. **Прозрачность.** Юзер видит в карточке правила не массивы суффиксов, а понятные параметры («Outbound», «DNS server») и описания.
4. **Масштабируемость.** Добавить новый пресет = дописать JSON. Ничего в коде менять не надо — рендерер UI универсален, експандер универсален.

### Что не меняется

- `CustomRule(kind: inline)` и `CustomRule(kind: srs)` — без изменений, спека 030 в силе. Юзерские правила (Firefox на .ru, кастомный SRS) остаются data-копиями.
- Существующие правила после апгрейда — не трогаются. Никакой one-shot миграции "inline → preset".

---

## Модель

### Шаблон

Финальная форма `Russian domains direct` (по состоянию 1.5):

```json
{
  "selectable_rules": [
    {
      "preset_id": "ru-direct",
      "label": "Russian domains direct",
      "description": "Route Russian & Cyrillic TLDs directly.",
      "default": true,

      "vars": [
        {"name": "out", "type": "outbound", "default_value": "direct-out", "title": "Outbound"},
        {"name": "dns_server", "type": "dns_servers", "required": false, "default_value": "yandex_doh", "title": "Transport"},
        {"name": "dns_ip", "type": "enum", "default_value": "77.88.8.88", "title": "UDP server IP",
         "tooltip": "Применяется только к UDP. DoH/DoT используют зашитые 77.88.8.88 + safe.dot.dns.yandex.net.",
         "options": [
           {"title": "77.88.8.88 · Safe",      "value": "77.88.8.88"},
           {"title": "77.88.8.2 · Safe alt",   "value": "77.88.8.2"},
           {"title": "2a02:6b8::feed:bad · Safe v6", "value": "2a02:6b8::feed:bad"},
           {"title": "77.88.8.8 · Base",       "value": "77.88.8.8"},
           {"title": "77.88.8.7 · Family",     "value": "77.88.8.7"}
         ]}
      ],

      "rule_set": [
        { "tag": "ru-domains", "type": "inline", "format": "domain_suffix",
          "rules": [{ "domain_suffix": [...] }] }
      ],

      "dns_rule": { "rule_set": "ru-domains", "server": "@dns_server" },
      "rule":     { "rule_set": "ru-domains", "outbound": "@out" },

      "dns_servers": [
        {"type": "https", "tag": "yandex_doh", "server": "77.88.8.88", "server_port": 443, "path": "/dns-query", "tls": {"enabled": true, "server_name": "safe.dot.dns.yandex.net"}, "detour": "@out", "description": "Yandex Safe DoH"},
        {"type": "tls",   "tag": "yandex_dot", "server": "77.88.8.88", "server_port": 853, "tls": {"enabled": true, "server_name": "safe.dot.dns.yandex.net"}, "detour": "@out", "description": "Yandex Safe DoT"},
        {"type": "udp",   "tag": "yandex_udp", "server": "@dns_ip",    "server_port": 53,  "detour": "@out", "description": "Yandex UDP (IP from above)"}
      ]
    }
  ]
}
```

**Почему DoH/DoT хардкодят server=IP + tls.server_name:**
В sing-box 1.12 DNS type=`https`/`tls` с hostname-сервером требует `domain_resolver` — тег другого DNS-сервера для bootstrap-резолва (chicken-and-egg). Указывая IP напрямую + `tls.server_name` — избавляемся от bootstrap'а (не нужно 8.8.8.8 для резолва `safe.dot.dns.yandex.net`), сохраняем TLS safety (cert verify по SNI-имени).

**Почему `@dns_ip` применяется только к UDP:**
Подмена IP для DoH/DoT без одновременной правки SNI сломает TLS (cert mismatch). Две оси (IP × mode) без nested-lookup в substitution-движке не разнести — YAGNI. Если потребуется Base/Family с DoH — отдельные пресеты.

**Новые поля `SelectableRule`** (всё опциональные):

| Поле | Тип | Назначение |
|---|---|---|
| `preset_id` | `String` | Стабильный slug. Если пустой — пресет работает в legacy-режиме (без bundle, как в 1.4). |
| `vars` | `List<Map>` | Типизированные переменные пресета. |
| `dns_rule` | `Map?` | DNS-правило bundle'а (вставляется в `dns.rules` перед fallback). |
| `dns_servers` | `List<Map>` | DNS-серверы bundle'а. Регистрируется **только выбранный** через `@dns_server`. |
| `rule_set` | `List<Map>` | Как в 1.4, но теперь обязательно в формате rule-set **definitions** (`{tag, type, format, rules\|url}`), а не DNS-rule. |
| `rule` | `Map` | routing-правило, как в 1.4, но может содержать `@var`. |

**Новые типы переменных:**

| `type` | Семантика | Подстановка |
|---|---|---|
| `outbound` | picker outbound-тегов (`direct-out` + все активные preset-группы) | строка-тег |
| `dns_servers` | picker tag'ов из `preset.dns_servers` | строка-тег |
| `enum` | dropdown из `options[]` с `title → value` | строка (`value`) |
| `text`/`bool`/`number` | скаляры | строка |

**`options` — расширенный синтаксис (`WizardOption`):**

```json
"options": [
  "simple_literal",                              // legacy: title==value
  {"title": "Human-readable label", "value": "machine_id"}  // labelled
]
```

Parser (`WizardOption.fromAny`) принимает оба формата. Строка `"foo"` эквивалентна `{title: "foo", value: "foo"}`. В UI показывается `title`, в `varsValues` / substitution используется `value`. Обратная совместимость для всех существующих `enum`-vars в `sections[]` (log_level, etc.) — без миграций.

**Флаг `required`** (default `true`):
- `true` — значение обязательно. В UI нет опции "—". Если `default_value` пустой → ошибка валидации шаблона (пресет skip + warning).
- `false` — в UI появляется пункт "— (default/none)". При выборе → `varsValues[name] = ""`. Expansion различает `containsKey=false` (юзер не трогал → `default_value`) от `value=""` (explicit none → `null`).

### `CustomRule`

```dart
enum CustomRuleKind { inline, srs, preset }     // добавлен `preset`

class CustomRule {
  final String id;
  String name;
  bool enabled;
  CustomRuleKind kind;

  // --- preset-only ---
  String presetId;                    // ссылка на SelectableRule.presetId
  Map<String, String> varsValues;     // значения переменных. null = ключа нет.

  // --- inline/srs (existing) ---
  List<String> domains, domainSuffixes, ...;
  String srsUrl;
  String target;
  ...
}
```

Для `kind == preset` все поля матч/target игнорируются. `name` остаётся (юзер может переименовать display-лейбл).

---

## Expansion

**Pure function.** Принимает `CustomRule(kind: preset)` и соответствующий `SelectableRule`, возвращает `PresetFragments`:

```dart
class PresetFragments {
  final List<Map> dnsServers;   // 0-1 элемент (выбранный через @dns_server)
  final Map? dnsRule;            // null если dropped (unresolved optional var)
  final List<Map> ruleSets;      // определения rule-set
  final Map? routingRule;        // null если dropped
}
```

### Алгоритм

1. **Собрать varsMap:** для каждой `preset.vars[i]`:
   - **`i.name` есть в `rule.varsValues`** — юзер явно трогал контрол в UI:
     - значение непустое → используется как есть.
     - **пустое** (`""`) → explicit "— (default/none)". Для `optional` → `null`. Для `required` → broken-preset warning (UI не даёт выбрать пусто для required, это защитный бранч).
   - **`i.name` отсутствует в `rule.varsValues`** — юзер не трогал:
     - `default_value` непустой → применяется.
     - `default_value` пустой + `required` → broken-preset warning.
     - `default_value` пустой + `optional` → `null`.

   Отсутствие ключа ≠ пустая строка: первое означает "юзер оставил default", второе — "юзер активно выбрал none". Это различие нужно потому что `default_value` может быть осмысленным (`yandex_doh`), и просто "не трогал dropdown" не должен выкидывать DNS-сервер из конфига.

2. **Для каждого фрагмента** (`rule_set`, `dns_rule`, `rule`, `dns_servers`) рекурсивно обойти JSON, применить `_substitute(value, varsMap)`:
   - `"@name"` → значение из varsMap.
   - Если значение `null` → **удалить ключ целиком из родителя** (не оставлять `"@name"` как литерал).
   - Если после удаления родительский Map становится пустым (в критичных местах — `rule.outbound`, `dns_rule.server`) → фрагмент целиком сбрасывается.

3. **Фильтр dns_servers:** оставить только те, у которых `tag == varsMap['dns_server']`. Если `dns_server == null` — пустой массив.

4. **Специальное правило для `detour` в dns_servers:** если значение `@out` резолвится в `"direct-out"` → ключ `detour` удалить (direct не требует detour'а, sing-box будет резолвить через default_domain_resolver).

5. **Universal outbound override:** `rule.varsValues['outbound']` — **всегда** имеет право перебить финальное routing-решение пресета, даже если в шаблоне нет `@outbound`-плейсхолдера или есть hardcoded `action`/`outbound`. Применяется **после** substitute'а (не через `varsMap`, потому что у пресета может не быть `outbound`-vars'ы — см. Block Ads `rule: {rule_set, action: reject}`).

   Семантика (реализуется в `preset_expand.dart` перед dangling-rule_set guard):
   - `override` отсутствует или пустая строка → template-решение as is.
   - `override == "reject"` → routing rule получает `action: "reject"`, существующий `outbound` удаляется (sing-box не принимает `outbound: "reject"` — это не tag).
   - `override == <любой tag>` → routing rule получает `outbound: <tag>`, существующий `action` удаляется.

   Это делает две формы template'а — `rule.action: "reject"` (shorthand) и `rule.outbound: "@outbound"` + `vars.outbound.default: "reject"` (explicit) — **семантически эквивалентными**. Template выбирает более компактную запись, UI-override работает одинаково в обоих случаях.

   **Следствие для UI:** OutboundPicker показывается на любом preset-правиле — Block Ads можно сменить с reject на vpn-1, Russian domains direct — с direct на reject, и так далее. Shorthand `action: "reject"` в шаблоне означает только "default", не "lock".

6. **Вернуть `PresetFragments`.**

### Merger

```dart
class BundleMerge {
  final List<Map> dnsServers;
  final List<Map> dnsRules;
  final List<Map> ruleSets;
  final List<Map> routingRules;
  final List<String> warnings;
}

BundleMerge mergeFragments(List<PresetFragments> all) {...}
```

**Стратегия:**
- `dnsServers` — append по `tag`. **Identical skip** (один tag, одинаковый остальной контент) — тихо. **Real conflict** (tag совпал, контент разный) — первый выигрывает, второй skip + warning через `app_log`.
- `ruleSets` — append по `tag`. Те же правила.
- `dnsRules`, `routingRules` — просто append (нет тэгов). Порядок — по порядку CustomRule в UI (детерминированный).

**Порядок в финальном конфиге:**
- `dns.rules` = `mergedDnsRules + templateDnsRules` — bundle-правила **перед** fallback `{"server": "google_doh"}` (template.dnsOptions.rules обычно содержит fallback в хвосте).
- `dns.servers` = `templateDnsServers + mergedDnsServers` — template-серверы первыми (fallback/default), bundle-серверы после.
- `route.rule_set` += `mergedRuleSets` (через `RuleSetRegistry` — reuse collision handling).
- `route.rules` += `mergedRoutingRules` (в хвост, перед route-level fallback если есть).

---

## Integration

Expansion встраивается в `applyCustomRules` (`lib/services/builder/post_steps.dart`):

```
for (cr in customRules) {
  switch (cr.kind) {
    case inline: ... (existing)
    case srs:    ... (existing)
    case preset:
      preset = template.selectableRules.firstWhereOrNull((p) => p.presetId == cr.presetId)
      if (preset == null) → warning "preset X not found" + skip
      else → fragments.add(expandPreset(cr, preset, ctx))
  }
}

merge = mergeFragments(fragments)

// Merge в registry:
for (rs in merge.ruleSets) registry.tryRegister(rs)   // identical-skip
for (r  in merge.routingRules) registry.addRule(r)

// DNS:
extraDnsServers = merge.dnsServers
extraDnsRules   = merge.dnsRules
```

`buildConfig` прокидывает `extraDnsServers/Rules` в `applyCustomDns`:

```dart
await applyCustomDns(
  config,
  template.dnsOptions,
  extraServers: extraDnsServers,
  extraRules: extraDnsRules,
);
```

`applyCustomDns` мерджит:
- `servers` = `filter(enabled, templateServers) + extraServers`
- `rules` = если нет user-override: `extraRules + templateRules`; иначе user wins (как сейчас).

**Почему `applyCustomDns` принимает extras, а не модифицирует `template.dnsOptions`:** template — immutable (shared cache между вызовами), модифицировать его in-place = race. Extras проходят отдельно.

---

## UI

### Tile на `RoutingScreen` — универсальный outbound override

На главной вкладке Rules tile preset-правила показывает `OutboundPicker` **всегда**, независимо от формы template'а:

- Bundle с `vars.outbound` (`Russian domains direct`) → picker изначально показывает default var'ы (`direct-out`).
- Bundle с shorthand `rule.action: "reject"` (`Block Ads`) → picker показывает **"Reject"** как текущий default.
- Bundle с hardcoded `rule.outbound: "direct-out"` (`Russia-only services direct`) → picker показывает `direct` как default.
- Юзер может переключить на любой другой канал (vpn-1, reject, direct, auto…) в любой из этих кейсов; override пишется в `varsValues['outbound']` и применяется универсально в `preset_expand` (см. Expansion §5).

Следствие для автора шаблона: форма `rule.action: "reject"` и форма `rule.outbound: "@outbound"` + `vars.outbound.default: "reject"` **семантически идентичны**. Первая короче, вторая явнее. Выбор — стилистический. Юзер в обоих случаях может переопределить decision через tile-picker.

Значение picker'а вычисляется через `_presetOut` (`routing_screen.dart`):
1. `rule.varsValues['outbound']` explicit
2. `preset.vars.firstWhere(name == 'outbound').default_value`
3. `preset.rule['action']` (shorthand — `reject` → picker показывает "Reject")
4. `preset.rule['outbound']` literal (hardcoded без `@`)
5. fallback `'direct-out'`

### Карточка правила (`CustomRuleEditScreen`)

Для `kind == preset`:

```
┌────────────────────────────────────────┐
│ ← Edit rule                         ⋮  │
├────────────────────────────────────────┤
│  ╭──────────────────────────────────╮  │
│  │ 📎 Based on preset               │  │
│  │    Russian domains direct        │  │
│  │    Route Russian & Cyrillic TLDs │  │
│  │    directly.                     │  │
│  ╰──────────────────────────────────╯  │
│                                        │
│  Enabled                     [ ●○○ ]  │
│  Name                                  │
│  [ Russian domains direct          ]  │
│                                        │
│  ─── Parameters ─────────────────────  │
│                                        │
│  Outbound                              │
│  [ direct-out                    ▼ ]  │
│                                        │
│  DNS server               (optional)  │
│  [ Yandex DoH                    ▼ ]  │
│                                        │
│  ─── Preview ────────────────────────  │
│  ▾ View JSON                           │
│    { "dns_options": { ... },           │
│      "route": { ... } }                │
│                                        │
│  [ 🗑  Delete rule ]                  │
└────────────────────────────────────────┘
```

Match-поля (domains/ports/packages/ip/protocol) **не показываются**. Редактирование bundle-контента — через шаблон, не через UI.

**Broken preset** (шаблон не содержит такого `preset_id`):
```
│  ⚠  Preset 'ru-direct' no longer       │
│     exists in this version of the app. │
│     [ 🗑  Delete rule ]                │
```
Форма vars не показывается. Во время сборки такое правило skip + warning.

### Список правил (`RoutingScreen`)

Бейдж `preset` у карточки. Subtitle = `preset.label` + short var summary: `"Russian domains direct · via direct-out · Yandex DoH"`.

### "Copy to Rules" из каталога Presets

- Если пресет имеет `preset_id` → создаётся `CustomRule(kind: preset, presetId: ..., varsValues: {})`. Дефолты применяются на лету через `expandPreset` (не хранятся в storage, чтобы пресет-update автоматически обновлял поведение).
- Если нет `preset_id` → legacy-режим, как в 1.4: создаётся `CustomRule(kind: inline/srs)` через `selectableRuleToCustom`.

### Seed на fresh install

Для каждого `selectable_rule` с `default: true`:
- Если есть `preset_id` → seed как `CustomRule(kind: preset)`.
- Иначе legacy путь (как в 1.4).

---

## Migration

- **Upgrade с 1.4.x:** существующие `CustomRule` в storage остаются `kind: inline/srs` — ничего не трогаем. Юзер сам удалит если захочет пересоздать как preset.
- **Seed presets fresh-install migrated flag** (`presets_migrated` в SettingsStorage) — не меняется, срабатывает как в 1.4.
- **Новый seed flag** `presets_seeded_v2` — если false и уже мигрировали в 1.4, при первом запуске 1.5 добавляем новые preset-based CustomRule для default-пресетов с `preset_id`, которых ещё нет в user storage. Идемпотентно, можно повторить.

---

## Edge cases

### unresolved required var

Пустой `default_value` + нет значения у юзера + `required: true`. Builder: skip правило, warning `"preset ru-direct: var 'out' required but unset"`. UI: форма не даёт save без значения (валидация на уровне редактора).

### `@out == "direct-out"` в DNS servers

Ключ `detour` удаляется из каждого bundle-DNS-сервера. Sing-box резолвит через `default_domain_resolver` или напрямую, без forwarding.

### Цикл в `@var`

Невозможен — vars ссылаются только на скаляры (primitive values), не на другие vars. Подстановка одноуровневая.

### Конфликт тегов между inline-правилом юзера и bundle-пресетом

`RuleSetRegistry.addRuleSet` имеет auto-suffix (spec 030). Для bundle-rule-set расширяем: `tryRegister(rs)` возвращает existing tag при identical содержимом (по deep-equal). Для non-identical — fallback на auto-suffix.

### Два пресета с одним `tag: yandex_doh` под разными `@out`

Detour в expanded-content будет разный → identical-skip не сработает → первый пишет `detour: vpn-1`, второй skip + warning. Правильно с точки зрения sing-box (один tag — один сервер).

*Решение для future:* можно неймспейсить по `preset_id` (например `yandex_doh@ru-direct`). Сейчас — first-wins + warning, юзер видит в логах.

### user-override DNS rules

Если юзер руками редактировал `dns.rules` через Settings (`getDnsRules`), bundle-rules **не** добавляются (полный override). Bundle-rules попадают в конфиг только когда нет user-override. DNS-серверы — наоборот: bundle-серверы всегда добавляются.

*Rationale:* user-override DNS rules — сознательный акт; молча дописывать bundle-правила поверх нечестно. DNS-серверы — больше похоже на reference data (тег вверху, правила внизу).

---

## Тестирование

- `preset_expand_test.dart` — pure-function expansion:
  - все vars заданы → полные фрагменты
  - optional var = null → фрагменты с `@var` dropped
  - required var + null + empty default → empty fragments + warning
  - `@out == direct-out` → `detour` удалён из dns_servers
  - фильтр dns_servers по `@dns_server`
- `bundle_merge_test.dart` — merger:
  - identical-skip (два preset-правила с одинаковым `yandex_doh`)
  - real conflict (разный content под одним tag) → first-wins + warning
  - детерминированный порядок по индексу rule
- `custom_rules_test.dart` — integration через `applyCustomRules`:
  - mix of inline + preset правил
  - broken preset (presetId не найден) → warning + skip
- `selectable_to_custom_test.dart` — seed / copy-to-rules:
  - пресет с `preset_id` → `CustomRule(kind: preset)` с пустыми `varsValues`
  - пресет без `preset_id` → legacy путь
- `build_config_test.dart` (integration) — финальный конфиг:
  - активный ru-direct preset → yandex_doh в `dns.servers`, DNS-rule перед fallback, rule_set в route
  - пресет disabled → bundle отсутствует
  - user-override DNS rules → bundle-rules skipped

---

## Not in scope

- Namespacing tag'ов пресетами (`yandex_doh@ru-direct`) — текущий first-wins + warning достаточен.
- Reactive обновление vars в runtime без reconfigure — любое изменение `varsValues` → reconfigure sing-box, как и сейчас для любой настройки.
- UI-редактор шаблона — шаблон остаётся asset, правится в коде, не из приложения.
- Импорт/экспорт пользовательских пресетов — отдельная фича (если понадобится).
