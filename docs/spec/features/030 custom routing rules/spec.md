# 030 — Unified Custom Routing Rules

| Поле | Значение |
|------|----------|
| Статус | **Active** (v1.4.0) |
| Дата | 2026-04-20 |
| Зависимости | [`013 routing`](../013%20routing/spec.md), [`011 local ruleset cache`](../011%20local%20ruleset%20cache/spec.md), [`026 parser v2`](../026%20parser%20v2/spec.md), [`027 subscription auto update`](../027%20subscription%20auto%20update/spec.md) |
| Убито/поглощено | **App Rules (AppRule)** — влиты в CustomRule.packages. **Selectable Rules toggle-механизм** — теперь каталог с "Copy to Rules". |

---

## Цель

**Одна модель** для всех пользовательских routing-правил в L×Box:
- per-app (был AppRule)
- per-domain / per-IP / per-port (был отдельный type'ом)
- per-protocol (bittorrent, tls, quic, ...)
- private-IP fast-path
- remote `.srs` rule_set (локально скачанные, без auto-update)

До v1.4.0 это были три параллельных механизма: `AppRule`, `SelectableRule` toggle'ы, и `CustomRule` (v1.3.x — с enum'ом type per rule). Теперь — один `CustomRule`, всё настраивается в одном редакторе.

---

## Семантика sing-box

Default rule matching (цитата из [docs](https://sing-box.sagernet.org/configuration/route/rule/)):

```
(domain || domain_suffix || domain_keyword || domain_regex
    || geosite || geoip || ip_cidr || ip_is_private || rule_set)
  && (source_geoip || source_ip_cidr || source_ip_is_private)
  && (source_port || source_port_range)
  && (port || port_range)
  && <other fields: protocol, package_name, process_name, ...>
```

- Внутри **одной категории** (domain-family) — **OR**
- Между категориями — **AND**
- `ip_is_private` и `rule_set` в той же domain-family группе (OR)
- `protocol`, `package_name` — "other fields" (AND)

Headless rule (inline rule_set) поддерживает **подмножество** этих полей. **Не поддерживают:**
- `protocol` — routing-rule level only
- `ip_is_private` — routing-rule level only
- `rule_set` — trivially routing-rule level (headless это сам rule_set)

Builder эмитит ненативные поля (protocol, ip_is_private) на routing-rule level, где они работают как OR/AND по sing-box formula выше.

---

## Модель

```dart
enum CustomRuleKind { inline, srs }

class CustomRule {
  final String id;                    // UUID, стабильный
  String name;
  bool enabled;
  CustomRuleKind kind;

  // OR-группа #1 (domain-family) — headless rule
  List<String> domains;
  List<String> domainSuffixes;
  List<String> domainKeywords;
  List<String> ipCidrs;

  // OR-группа #2 (port-family) — headless rule
  List<String> ports;                 // ["443","80"] → int array при emit
  List<String> portRanges;            // ["8000:9000",":3000","4000:"]

  // AND (routing-rule level, не headless)
  List<String> packages;              // package_name (per-app filter)
  List<String> protocols;             // ["tls","quic"] (L7 sniff)
  bool ipIsPrivate;                   // true → ip_is_private:true на routing-rule

  // srs-only
  String srsUrl;

  String target;                      // outbound tag ИЛИ kRejectTarget="reject"
}
```

### Ключевые инварианты

- `packages` в inline headless rule (sing-box его там поддерживает) → AND с domain/port внутри rule_set
- `protocols` и `ipIsPrivate` — **не в headless**, только на routing-rule level
- `id` — стабильный UUID (не меняется на rename), используется как ключ для SRS-кэша (`$docs/rule_sets/<id>.srs`)
- `srsUrl` — только для `kind=srs`, в конфиг **не попадает** (sing-box получает `type:local, path:…`)

---

## Emit: `applyCustomRules`

`lib/services/builder/post_steps.dart`.

### Inline (`kind == inline`)

Для каждого правила:
1. Собираем headless `match` map из непустых полей: `domain`, `domain_suffix`, `domain_keyword`, `ip_cidr`, `port` (int array), `port_range`, `package_name`.
2. Если `match` пустой **и** нет routing-level полей (protocols, ipIsPrivate) → skip.
3. Если `match` пустой но есть routing-level — эмитим routing rule без rule_set:
   ```json
   {"protocol": ["bittorrent"], "outbound": "direct-out"}
   ```
4. Если `match` непустой — эмитим inline rule_set + routing rule:
   ```json
   // rule_set
   {"type":"inline","tag":"<name>","rules":[{"domain_suffix":[".ru"],"port":[443],"package_name":["org.mozilla.firefox"]}]}
   // route rule
   {"rule_set":"<name>","protocol":["tls"],"ip_is_private":true,"outbound":"direct-out"}
   ```

### SRS (`kind == srs`)

1. Если в `_customRules` есть cached файл (`RuleSetDownloader.cachedPath(rule.id)`) — передаётся в `srsPaths` map из `build_config`.
2. Если path в map:
   ```json
   // rule_set
   {"type":"local","tag":"<name>","format":"binary","path":"/data/user/0/com.leadaxe.lxbox/files/rule_sets/<uuid>.srs"}
   // route rule
   {"rule_set":"<name>","port":[443],"protocol":["tls"],"package_name":["…"],"ip_is_private":true,"outbound":"direct-out"}
   ```
3. Если path нет — rule **skip**'ается, в `warnings` пушится `"SRS rule X skipped: no cached file"`. Тунель запускается, правило просто не работает пока юзер не нажмёт Download.

### Reject sentinel

`target == "reject"` (константа `kRejectTarget`) → в routing rule вместо `"outbound":"..."` эмитится `"action":"reject"`. Выбирается в UI как отдельная опция в OutboundPicker.

### Collision handling

Централизован в `RuleSetRegistry` — auto-suffix `"name (2)"`, `"name (3)"` при занятом tag'е. Template-defined inline rule_set'ы (напр. `ru-domains` из wizard) и user custom rules шарят namespace. UI валидирует уникальность имён пользовательских правил по `id` (exclude self) для предотвращения неожиданных `(2)` suffix'ов.

---

## SRS — local-only

Критичное отличие от v1.3.x: sing-box **никогда не качает** SRS файлы сам. L×Box качает через `RuleSetDownloader.download(id, url)` (в `lib/services/rule_set_downloader.dart`), кладёт в `$documents/rule_sets/<id>.srs`.

**Нет auto-update.** Никаких `update_interval` в конфиге. Refresh — только по явному нажатию юзера (☁ в списке или long-press → Refresh SRS). Причины:
- Провайдеры блокируют трафик / rate-limit'ят → автозапросы ломают IP.
- Юзер должен контролировать что когда обновляется (см. memory `feedback_no_unplanned_autoupdates`).

**Enable gate:** пока нет cached файла — switch правила **disabled**. Нельзя включить правило без контента.

**URL change / rule delete:**
- Смена URL в редакторе → на save cached файл стирается, switch сбрасывается.
- Delete rule → cached файл удаляется (`RuleSetDownloader.delete(id)`).

**Miss behavior:** rule enabled но файла нет — builder скипает правило + warning. Тунель запускается.

---

## Migration (one-shot)

### AppRule → CustomRule.packages

`SettingsStorage._absorbLegacyAppRules`: если в data есть ключ `app_rules`, конвертирует каждый entry в `CustomRule(kind:inline, packages:[...], target:outbound, enabled:…, name:…, id:…)` и merge'ит в `custom_rules`. После — key `app_rules` удаляется. Идемпотентно.

### enabled_rules + rule_outbounds → custom_rules

`RoutingScreen._migrateLegacyPresets`: при первой load'е (флаг `presets_migrated` в storage) конвертит enabled `SelectableRule`'ы через `selectableRuleToCustom` + применяет `rule_outbounds` как override target. Fresh installs получают seed из `template.selectableRules.where(r => r.defaultEnabled)`. После — флаг выставлен, больше не запускается.

`selectableRuleToCustom` (в `lib/services/selectable_to_custom.dart`) обрабатывает три формы пресетов:
1. `rule_set:[remote SRS]` → `CustomRule(kind:srs, srsUrl:...)`
2. `rule.rule_set:"<tag>"` ссылка на template inline rule_set → разворачивает match-поля
3. inline match-поля прямо в `rule` → передаются в CustomRule as-is

Поддерживает все match-поля включая `ip_is_private` и `protocol`.

---

## UI

### RoutingScreen — 3 tabs

```
Routing
┌─────────────────────────────────────────┐
│ Channels │ Presets │ Rules              │
├─────────────────────────────────────────┤
```

**Channels** — proxy groups + `route.final` selector (не изменилось).

**Presets** — read-only каталог. Каждый пресет из `wizard_template.json selectable_rules`:
- Label + description
- Кнопка **Copy to Rules** (или "In Rules" disabled, если по имени уже есть)
- Конвертит через `selectableRuleToCustom`, для srs'ов создаёт disabled rule (юзер должен скачать SRS сначала)

**Rules** — реестр пользовательских `CustomRule`. ReorderableListView.builder:
- Каждый tile: `|| drag-handle | Switch | Name + summary (2 строки) | ☁ (srs only) | OutboundPicker ▾ |`
- long-press → context menu → **Delete** (с confirm dialog)
- tap → open `CustomRuleEditScreen`
- Reorder через drag за `||` handle

### CustomRuleEditScreen

Tabs **Params** / **View**:

**Params:**
```
┌ Name [...] [Switch ●] ┐
│ Action: [direct-out ▾] │
├ APPS ──────────────────┤   ← над Source, сразу после Action
│ [Select apps...]        │
├ Source: (●) Inline  ( ) Remote (.srs) ┤
├ MATCH (OR within group) ┤
│ Domain [...]            │
│ Domain suffix [...]     │
│ Domain keyword [...]    │
│ IP CIDR [...]           │
│ [✓] Private IP          │
├ PORT (AND with match) ──┤
│ Port (exact) [...]      │
│ Port range [...]        │
├ PROTOCOL (AND) ─────────┤
│ [✓] tls [✓] quic ...    │
└ [Delete rule] ───────────┘
```

Для `kind=srs` вместо MATCH — RULE-SET URL с cloud-иконкой (☁):
- tap → download/retry
- long-press → menu: **Refresh SRS** / **Clear cached file** (удаляет только файл, не rule; enabled сбрасывается)

URL prefix-иконка (🔗) — tap копирует URL в clipboard.

**View:** показывает sing-box config preview — JSON с `rule_set` + `rules`, собранный через тот же `applyCustomRules` со snapshot текущей формы. Поддерживает `Copy` button. Warnings (e.g. "no cached file") отображаются над preview'ом.

### Dirty check

`_isDirty()` сравнивает `jsonEncode(_snapshot().toJson()) != jsonEncode(widget.initial.toJson())`:
- Save IconButton подсвечивается `primary`-цветом когда dirty
- Back / leading arrow / system back → если dirty, показывается "Discard changes?" диалог (Keep editing / Discard)

---

## Storage

Единый ключ `custom_rules` в `lxbox_settings.json`:

```json
"custom_rules": [
  {
    "id": "uuid-1",
    "name": "Firefox on .ru direct",
    "enabled": true,
    "kind": "inline",
    "domainSuffixes": ["ru","xn--p1ai","su"],
    "packages": ["org.mozilla.firefox"],
    "target": "direct-out"
  },
  {
    "id": "uuid-2",
    "name": "Block Ads",
    "enabled": true,
    "kind": "srs",
    "srsUrl": "https://raw.githubusercontent.com/.../geosite-category-ads-all.srs",
    "target": "reject"
  }
],
"presets_migrated": true
```

SRS файлы — в `$documents/rule_sets/<id>.srs`. Не в json, on-disk binary.

Миграция old-format `custom_rules` (v1.3.x с `type`+`items`) **не поддерживается** — считаем что фича не шипилась широко до v1.4.0 (были только local builds).

---

## Файлы

| Файл | Что |
|------|-----|
| `lib/models/custom_rule.dart` | Модель `CustomRule` + `CustomRuleKind` + `kRejectTarget` + `kKnownProtocols` |
| `lib/services/builder/post_steps.dart` | `applyCustomRules(registry, rules, {srsPaths})` → `List<String>` (warnings) |
| `lib/services/builder/rule_set_registry.dart` | Централизованный `tag` allocator с auto-suffix |
| `lib/services/builder/build_config.dart` | Pre-resolve srsPaths через RuleSetDownloader → вызов applyCustomRules |
| `lib/services/rule_set_downloader.dart` | `download(id,url)`, `cachedPath(id)`, `isCached(id)`, `delete(id)`, `lastUpdated(id)` |
| `lib/services/selectable_to_custom.dart` | Конвертер SelectableRule → CustomRule (для Copy to Rules + миграции) |
| `lib/services/settings_storage.dart` | `getCustomRules`, `saveCustomRules`, `_absorbLegacyAppRules`, `hasPresetsMigrated`, `markPresetsMigrated` |
| `lib/screens/routing_screen.dart` | 3 tabs: Channels / Presets / Rules; ReorderableListView; long-press menu; SRS download state |
| `lib/screens/custom_rule_edit_screen.dart` | Params/View tabs; dirty check + discard dialog; cloud long-press menu |
| `lib/screens/app_picker_screen.dart` | Lazy-icon list; static pop-guard; safe import/export |
| `lib/widgets/outbound_picker.dart` | Shared dropdown (dense row + form) с `allowReject` |
| `test/builder/custom_rules_test.dart` | ~20 тестов: все поля, combinations, срс с/без кэша, protocols-only, reject, migration JSON |
| `test/services/selectable_to_custom_test.dart` | Конвертер: remote/ref/inline/missing/override |

---

## Acceptance

- [x] Routing → 3 таба (Channels / Presets / Rules)
- [x] Rules tile: drag-handle, switch (disabled для srs без cache), OutboundPicker, summary line, edge-to-edge
- [x] Long-press tile → confirm delete dialog (рядом с точкой нажатия)
- [x] Edit screen — Params / View таба; dirty-aware save icon; back с unsaved → Discard dialog
- [x] Params: APPS секция над Source, MATCH/PORT/PROTOCOL секции, чекбокс Private IP в MATCH
- [x] View: JSON preview через реальный applyCustomRules + warnings
- [x] Cloud icon в URL: tap=download, long-press=menu (Refresh/Clear cached file)
- [x] URL icon (🔗) клик = копирование
- [x] Preset copy → все match-поля (включая `ip_is_private`, `protocol`, template inline rule_set references) корректно мапятся
- [x] sing-box принимает конфиг (никаких unknown fields в headless)
- [x] `ip_is_private` на routing-rule level (AND с rule_set per sing-box formula)
- [x] `protocol` на routing-rule level
- [x] SRS: файл только локально, ноl `update_interval` в конфиге не эмитим
- [x] Migration enabled_rules + rule_outbounds + app_rules → custom_rules (с флагом presets_migrated)
- [x] 167+ тестов зелёные

---

## Memory / invariants

- **Никаких auto-update в сингбокс-конфиге** — `feedback_no_unplanned_autoupdates`. Все фетчи только через юзер-тап.
- **RuleSetRegistry — single source of truth** для rule_set'ов и routing rules. Post-steps не трогают `config['route']` напрямую.
- **CustomRule.id стабилен** — UUID генерится в конструкторе, persist'ится в JSON. Используется как primary key в identity-матчинге (dedup, SRS cache path, UI keys для reorder).

---

## Out of scope (на будущее)

- **domain_regex** в MATCH — не запрашивали, sing-box поддерживает, можно добавить textarea аналогично другим доменам
- **source_ip_cidr / source_port** — exotic, YAGNI
- **geoip / geosite** remote rule_sets — можно добавить как отдельный CustomRuleKind (или через srs если провайдер даёт .srs'ку с geoip)
- **process_name** (desktop-only) — не актуально для Android
- **Rule import/export** через JSON файл — deferred, view-tab + clipboard copy уже почти покрывает
