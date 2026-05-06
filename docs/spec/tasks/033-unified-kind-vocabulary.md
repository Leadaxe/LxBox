# 033 — Unified `kind` vocabulary across `custom_rules` + `dns_options.rules`

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-05-03 |
| Связанные spec'ы / таски | [`041 dns rules refactor`](../features/041%20dns%20rules%20refactor/spec.md), [`030 custom routing rules`](../features/030%20custom%20routing%20rules/spec.md), [`033 preset bundles`](../features/033%20preset%20bundles/spec.md), [`032 dns rules schema symmetry`](032-dns-rules-schema-symmetry.md) |

## Цель

Унифицировать `kind` discriminator между `custom_rules` (routing) и `dns_options.rules` (DNS) до общего словаря `inline | srs | preset | template`. После §032 они уже используют `kind` как имя поля, но значения разные:

- `custom_rules`: `inline` / `srs` / `preset`
- `dns_options.rules`: `user` / `template` / `rule` (после §032)

Это асимметрично концептуально: `inline` (custom_rules) ≡ `user` (dns_options), `preset` (custom_rules) ≡ `rule` (dns_options) — одинаковая семантика, разные имена. Также:
- DNS не имеет `kind: srs` (хотя sing-box это поддерживает на DNS-rules через `rule_set`-ссылку — реальный use case "geosite-cn → китайский DNS").
- Routing не имеет `kind: template` (template-default'ы для DNS уникальны — DNS требует always-present fallback rule).

Дополнительно — `preset` сейчас **всё-или-ничего**: включил CustomRulePreset → активен и его route, и его DNS. Юзер не может отключить только DNS-side (или только routing-side) пресета.

## Что меняем

### 1. Унифицированный `kind` set: `inline | srs | preset | template`

| kind | в `custom_rules` | в `dns_options.rules` | смысл |
|---|---|---|---|
| `inline` | ✓ | ✓ | body inline в записи (для route — match-fields + outbound; для DNS — sing-box DNS-rule shape) |
| `srs` | ✓ | ✓ (model only, UI не делаем) | rule_set по cached `.srs`, body inline + srsUrl + extra fields |
| `preset` | ✓ | ✓ | proxy на active preset; в обоих списках с **общим `presetId`** и **независимым `enabled`** |
| `template` | ✗ | ✓ | proxy на template-default из шаблона; DNS-only (для route'инга template-defaults пока нет) |

### 2. `kind: preset` — single source, independent enable

Один `presetId` живёт **дважды** в storage:

```jsonc
"custom_rules": [
  {
    "id": "r_1714503333",
    "name": "Russian domains direct",
    "enabled": true,                      // ← включает route side (rule + rule_sets)
    "kind": "preset",
    "presetId": "ru-direct",              // ← KEY
    "varsValues": {                       // ← хранится ТОЛЬКО ЗДЕСЬ
      "outbound": "direct-out",
      "dns_server": "yandex_doh"
    }
  }
],
"dns_options": {
  "rules": [
    {
      "enabled": false,                   // ← независимый flag для DNS side
      "kind": "preset",
      "presetId": "ru-direct"             // ← MATCHES custom_rules.presetId
      // varsValues НЕ хранятся — берутся из custom_rules при expand
    }
  ]
}
```

Возможные state'ы (4-х комбинаций):

| custom_rules.enabled | dns_options.preset.enabled | Что эмитится |
|---|---|---|
| true | true | route + DNS оба активны (legacy behavior) |
| true | false | только route активен; DNS-rule пресета пропускается |
| false | true | только DNS-rule активен; route пропускается. **Это новая фича** — раньше нельзя было |
| false | false | preset полностью неактивен (но storage entries сохраняются) |

### 3. Auto-link при creation, mandatory link при deletion

**Auto-link:** при добавлении `custom_rules.kind:preset` для preset'а с `dns_rule` в шаблоне — автоматически создаётся соответствующая `dns_options.rules.kind:preset` запись (с `enabled: true`, в положенном месте default-order'а — перед template-блоком).

Симметрично, при добавлении `kind: preset` через UI DnsSettings (если такую возможность дадим) — auto-create в `custom_rules` тоже. Реалистично — UI добавления preset'а в DnsSettings можно не делать, тогда `kind: preset` в `dns_options.rules` появляется только через RoutingScreen.

**Mandatory link при deletion:** удаление `custom_rules.kind:preset` ⇒ удаление соответствующей `dns_options.rules.kind:preset` записи. И обратно: удаление `dns_options.rules.kind:preset` ⇒ удаление `custom_rules.kind:preset` (с подтверждением, потому что user может не ожидать что заодно потеряет route side).

Обоснование: `varsValues` живут только в `custom_rules` entry. Если разрешить разрозненное удаление, DNS-entry без routing-entry теряет источник `varsValues` для expansion → broken state.

В UI: при удалении preset в RoutingScreen — silent cleanup DNS-side (не спрашиваем — единый объект). При удалении preset в DnsSettings (если позволим) — confirm dialog "Это также удалит соответствующее routing-правило".

### 4. `kind: srs` для DNS

Расширение модели `dns_options.rules` чтобы поддерживать тот же тип, что и `custom_rules.kind: srs`:

```jsonc
{
  "enabled": true,
  "kind": "srs",
  "name": "China domains → CF",
  "srsUrl": "https://.../geosite-cn.srs",
  "rule": {                               // sing-box DNS rule body
    "server": "cloudflare_doh"
    // rule_set ссылка инжектируется builder'ом из srsUrl кэша
  }
}
```

Builder при emit:
1. Resolve `srsUrl` → cached path (через `RuleSetDownloader.cachedPath(<id>)`, как для route srs)
2. Регистрирует rule_set: `{type: local, tag: <gen>, format: binary, path: <cache>}`
3. Эмитит DNS-rule: `{rule_set: <gen tag>, server: rule.server, ...}`

Если кэша нет — правило skip'ается с warning'ом (как для route srs).

UI в DnsSettings **пока не делаем** — добавление user srs в DNS будет в отдельной таске (включая cache management UI, аналогичный routing'овому). Сейчас только модель + builder + миграция-ready storage shape.

### 5. Field rename: `title` → `name` для DNS storage и template

После §032 в `dns_options.rules` для `kind: user` лежит `title` (freeform user label), для `kind: template` лежит `title` (matches `wizard_template.json/dns_options.rules[i].title`).

`custom_rules` использует `name` для тех же ролей (user-given label у inline/srs).

Унификация: переименовать `title` → `name` везде. Применяется к:
- `wizard_template.json/dns_options.rules[i].title` → `name`
- `dns_options.rules` storage entries `title` → `name` (для `kind: inline`/`template`/`srs`)
- `kind: preset` — поле `name` отсутствует (UI рендерит через `template.selectableRules.firstWhere(...).label`, как и сейчас)

Обоснование: `custom_rules.name` уже shipped, переименование DNS-side под него симметричнее чем обратный путь.

## Storage shape — final

### `custom_rules`

Без изменений семантики, но `kind: preset` теперь имеет independent `enabled` от DNS-аспекта:

```jsonc
"custom_rules": [
  {"id": "...", "name": "...", "enabled": true, "kind": "inline", /* match-fields + outbound */},
  {"id": "...", "name": "...", "enabled": true, "kind": "srs", "srsUrl": "...", /* + extra fields */, "outbound": "..."},
  {"id": "...", "name": "...", "enabled": true, "kind": "preset", "presetId": "ru-direct", "varsValues": {...}}
]
```

### `dns_options.rules`

```jsonc
"dns_options": {
  "rules": [
    {"enabled": true,  "kind": "inline",   "name": "RU IPs", "rule": {...}},
    {"enabled": true,  "kind": "srs",      "name": "CN sites", "srsUrl": "...", "rule": {...}}, // model only
    {"enabled": false, "kind": "preset",   "presetId": "ru-direct"},                            // linked to custom_rules
    {"enabled": true,  "kind": "template", "name": "Default → Google DoH"}                       // proxy на template
  ]
}
```

### `wizard_template.json` template defaults

Изменение в шаблоне:

```jsonc
"dns_options": {
  "rules": [
    {"name": "Default → Google DoH", "enabled_default": true, "server": "google_doh"}
    //  ↑ было "title"
  ]
}
```

## Изменения в коде

### Models

**`CustomRuleKind` enum** — без изменений (`inline` / `srs` / `preset` уже есть).

**Builder/storage logic** — изменения семантики (см. ниже).

### `expandPreset` / `applyPresetBundles`

Сейчас expand вызывается только если `custom_rules.kind:preset.enabled == true`. Меняем: expand вызывается если хотя бы одна сторона активна (route OR DNS). Эмит уже фильтруется по аспекту.

```dart
PresetApplyResult applyPresetBundles(
  RuleSetRegistry registry,
  List<CustomRule> rules,                         // custom_rules
  List<Map<String, dynamic>> dnsRules,            // dns_options.rules — нужны для проверки .preset.enabled
  List<SelectableRule> presets, {
  Map<String, String> presetSrsPaths = const {},
}) {
  // Build set of dns-enabled presetIds (для каждого presetId — bool)
  final dnsEnabledByPresetId = <String, bool>{};
  for (final e in dnsRules) {
    if (e['kind'] == 'preset' && e['presetId'] is String) {
      dnsEnabledByPresetId[e['presetId']] = e['enabled'] == true;
    }
  }

  for (final cr in rules) {
    if (cr is! CustomRulePreset) continue;
    final routeEnabled = cr.enabled;
    final dnsEnabled = dnsEnabledByPresetId[cr.presetId] ?? false;
    if (!routeEnabled && !dnsEnabled) continue;  // обе выключены — skip expand

    final fragments = expandPreset(cr, match, srsPaths: ...);
    fragmentsList.add(_FilteredFragments(
      fragments: fragments,
      includeRoute: routeEnabled,
      includeDns: dnsEnabled,
    ));
  }

  // mergeFragments + emit фильтрует по includeRoute/includeDns:
  // - rule_sets: если ни одна aspect не активен — не нужны; если route активен — нужны для route emit; если только dns — нужны для dns srs (если referenced)
  // - routingRule: emit только если route active
  // - dnsRule: возвращается в byPresetId map только если dns active (applyCustomDns его не возьмёт если active='false', но проще filter здесь)
  // - dnsServers: возвращаются всегда для пресета у которого route OR dns active (могут понадобиться для DNS even если route disabled)
}
```

### `resolveDnsRulesList`

Migration step (§033 layer поверх §032):
- `kind: rule` → `kind: preset` (rename, presetId field остаётся как есть)
- `kind: user` → `kind: inline` (rename), `title` → `name`
- `kind: template`: `title` → `name`

Идемпотентно (второй проход видит уже migrated и skip).

Auto-discovery меняется: при появлении новой `custom_rules.kind:preset` (если у preset'а есть `dns_rule`) — auto-create запись `{enabled: true, kind: preset, presetId: <pid>}` в `dns_options.rules`. Если запись уже есть — оставляем enabled как есть (не override'им user toggle).

Orphan cleanup:
- `kind: template` с `name` не в template → orphan
- `kind: preset` без соответствующей `custom_rules.kind:preset` записи → orphan (mandatory link нарушен — может произойти если ручное правка storage; UI не должен такое создавать)
- `kind: inline`/`srs` — никогда orphan, всегда сохраняются

### `applyCustomDns`

Меняется для нового kind set:

```dart
for (final entry in resolved) {
  if (entry['enabled'] != true) continue;
  final kind = entry['kind'] as String?;
  if (kind == 'inline') {
    final body = entry['rule'];
    if (body is Map<String, dynamic>) outRules.add(body);
  } else if (kind == 'srs') {
    // resolve srsUrl → cached path → register rule_set + emit DNS rule
    // (см. отдельную секцию "kind: srs для DNS")
  } else if (kind == 'preset') {
    final pid = entry['presetId'] as String?;
    final body = extraDnsRulesByPresetId[pid];
    if (body != null) outRules.add(body);
  } else if (kind == 'template') {
    final name = entry['name'] as String?;
    final t = templateRulesByName[name];  // было templateRulesByTitle
    if (t != null) outRules.add(_strip(t));
  }
}
```

### UI

**RoutingScreen:**
- При добавлении preset (CustomRulePreset) — после save → auto-create `kind: preset` запись в `dns_options.rules` (если у preset'а есть `dns_rule`).
- При удалении preset → silent cleanup `dns_options.rules.kind:preset` запись с тем же presetId.
- Toggle preset в RoutingScreen — НЕ трогает DNS-side enabled (independent). UI можно показать sub-text "DNS-aspect: enabled/disabled" мелким текстом, чтобы юзер понимал текущее состояние.

**DnsSettingsScreen:**
- `kind: preset` запись имеет independent toggle (как сейчас).
- При попытке удалить `kind: preset` запись — confirm "This also removes the routing aspect of this preset" → удаление обоих.
- `kind: srs` пока не показывается (model only).
- `kind: inline` (бывший `user`) — прежнее поведение editable + delete.
- `kind: template` — proxy read-only (`name` instead of `title` теперь, без видимых для юзера изменений).

## Migration

**Никакой migration-логики в коде нет.** §041 + §032 в проде нигде не shipped (только на dev-телефоне), переписывать legacy storage не стоит.

Поведение:
- Старые ключи (`kind: rule`, `kind: user`, `title`, etc.) builder/UI просто не распознают.
- В `resolveDnsRulesList` неузнанные `kind`-значения проваливаются мимо всех `if/else if` веток → запись отсеивается на orphan-фильтре (нет body для resolve, не template title, не presetId match).
- Auto-discovery восстанавливает свежий набор записей из current template + active presets.

Эффект для dev-телефона: после первого open `DnsSettingsScreen` старые legacy-записи уйдут, новые auto-create'нутся в правильном shape. Юзер ничего не теряет (преcет всё ещё в `custom_rules`, template-defaults в шаблоне — всё восстанавливается).

`wizard_template.json` (`title` → `name`) правится в коде один раз на релиз.

## Test plan

### Unit-тесты (post_steps_test.dart, dns_rules_resolver_test.dart)

1. **Auto-link creation:** добавили `custom_rules.kind:preset` → resolve создал `dns_options.rules.kind:preset` с тем же presetId.
2. **Mandatory link deletion:** удалили `custom_rules.kind:preset` → следующий resolve выкидывает orphan'а в `dns_options.rules`.
3. **Independent enable:**
   - `cr.enabled=true, dns.enabled=true` → route + dns rules в финальном конфиге
   - `cr.enabled=true, dns.enabled=false` → только route
   - `cr.enabled=false, dns.enabled=true` → только dns
   - `cr.enabled=false, dns.enabled=false` → ни того ни другого
4. **`kind: srs` для DNS:** запись с srsUrl + cached path → builder регистрирует rule_set + эмитит DNS-rule.
5. **Field rename:** builder читает только `name` из шаблона. Старый `title` в шаблоне не поддерживается (релизом меняем сразу).
6. **Legacy ignore:** запись с `kind: rule` или `kind: user` или с полем `title` (после §032) — silently dropped в orphan фильтре.

### UI smoke

- RoutingScreen: добавил preset → DnsSettings показывает соответствующую `kind: preset` запись.
- RoutingScreen: удалил preset → DnsSettings её не показывает.
- DnsSettings: toggle preset OFF → запустил VPN, проверил `/state/storage` (dns.rules не содержит preset'овской entry, route.rules содержит).
- DnsSettings: попытка удалить `kind: preset` → confirm dialog → удаляет обе записи.

## Стоимость

- **Models:** rename внутри `CustomRule` нет (`inline`/`srs`/`preset` уже там). Только storage shape DNS меняется.
- **Builder:** ~50 строк изменений в `expandPreset`/`applyPresetBundles`/`applyCustomDns`/`resolveDnsRulesList`.
- **UI:** ~30 строк в `DnsSettingsScreen` (rename + confirm dialog), ~20 строк в `RoutingScreen` (auto-link create/delete hooks).
- **Tests:** ~10 новых кейсов в `dns_rules_resolver_test.dart` + ~3 в `apply_preset_bundles_test.dart`.
- **wizard_template.json:** 1-line edit (`title` → `name` у DNS-rules) + версия comment.
- **Spec 041:** обновить shape examples.

Объём ~1.5х от §032 (за счёт independent enable + auto-link logic).

## Не в скопе

- UI для добавления `kind: srs` в DnsSettings — отдельной таской.
- UI для добавления `kind: preset` напрямую в DnsSettings (без routing entry) — отдельной таской.
- Symmetry для `dns_options.servers` (per-server enable из preset) — отдельной фичей.
- Template defaults для routing (если когда-нибудь захотим) — отдельной таской.
- Renaming `kind` → `node_kind` или другие косметические перемены — не в этом скопе.

## Verification

После имплементации:
1. Storage до апдейта: `dns_options.rules` имеет `{kind: rule, presetId}` (от §032).
2. Поставить новый APK → открыть DnsSettings → `resolveDnsRulesList` мигрирует на `{kind: preset, presetId}`.
3. Через `/state/storage` (Bearer-токен из App Settings) убедиться: kind: preset, name вместо title для inline/template, no `title` field у preset entries.
4. **Smoke independent enable:**
   - Tunnel up с активным `ru-direct` пресетом, обе стороны enabled.
   - В DnsSettings выключить `kind: preset` (route остаётся вкл).
   - VPN reload → `dns.rules` не содержит ru-direct, `route.rules` содержит.
   - Включить обратно DNS-aspect → reload → обе вернулись.
5. **Smoke auto-link на removal:**
   - В RoutingScreen удалить preset.
   - DnsSettings больше не показывает соответствующую DNS preset запись.
6. `flutter analyze` + `flutter test` — все зелёные, +новые тесты.
