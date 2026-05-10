# 061 — DNS rules refactor (named, toggleable, multi-source)

| Поле | Значение |
|------|----------|
| Статус | Done (рефакторная база, схема в продакшене; live spec — §014 dns settings) |
| Дата | 2026-05-02 |
| История | Был `features/041 dns rules refactor`, демотирован в task через §054 (refactor → результат описан в §014) |
| Зависимости | [`features/014 dns settings`](../../features/014%20dns%20settings/spec.md), [`features/033 preset bundles`](../../features/033%20preset%20bundles/spec.md) |
| Триггер | Открытие `DnsSettingsScreen` молча промоутит template defaults в user override (`dns_options.rules_json`), что заставляет builder игнорировать `extraRules` от активных пресетов. Симптом: preset `ru-direct` имеет `dns_rule: {rule_set: "ru-domains", server: yandex_doh}` — но в финальном конфиге его нет, RU-домены резолвятся через дефолтный resolver. Также в текущей модели DNS-правила хранятся одной строкой JSON без имён и без индивидуального enable — пользователь не может выбирать "это правило мне нужно, это нет". |

## Цель

Привести DNS-правила к first-class модели аналогично DNS-серверам (которые уже именованы и индивидуально toggle-able), и убрать silent override, ломающий пресеты.

Каждое DNS-правило имеет:
- `title` — имя (для template/rule — идентификатор; для user — freeform label)
- `enabled` — индивидуальный toggle
- `type` — `user` | `template` | `rule` (источник)
- `rule` — sing-box-shape body (только для `type: user`; для template/rule — proxy по title в текущий шаблон/активный preset)

Builder собирает финальный `dns.rules` линейным проходом по `dns_options.rules` в порядке массива, пропуская `enabled: false`. UI позволяет drag-handle reorder через все категории, инлайновое включение/выключение, добавление/удаление user-правил.

## Не в скопе

- Изменения в `dns_options.servers` — они уже именованы и toggle-able, остаются как есть.
- Авто-миграция старого `dns_options.rules_json` — поле остаётся в storage, но не читается. UI кнопки для импорта legacy-строки в новые user-rules не делаем (если кто-то писал — потеряют).
- Изменения в `dns.final` — singleton, остаётся как переменная (`@dns_final`).
- Reordering у DNS-серверов — отдельная задача если понадобится.

---

## Модель данных (после §032 schema cleanup)

### `dns_options.rules` — массив записей

```jsonc
{
  "enabled": true,
  "kind": "user" | "template" | "rule",     // ← дискриминатор source (бывший type)
  "title": "RU domains → Yandex",            // для kind: user/template
  "presetId": "ru-direct",                   // для kind: rule (бывший title==label)
  "rule": {                                  // ТОЛЬКО для kind: user
    "rule_set": "ru-domains",
    "server": "yandex_doh"
  }
}
```

| Поле | Тип | Семантика |
|------|-----|-----------|
| `enabled` | bool | Включить/выключить. `false` — запись остаётся в storage, builder её скипает. |
| `kind` | string | Источник правила (`user` / `template` / `rule`). Симметрично `custom_rules[i].kind`. |
| `title` | string | Идентификатор для kind=template (= `template.dnsOptions.rules[i].title`) или freeform label для kind=user. У kind=rule отсутствует. |
| `presetId` | string | Pointer на `selectable_rules[i].preset_id` для kind=rule. Immutable. У kind=user/template отсутствует. |
| `rule` | map | Sing-box DNS-rule body. Только для `kind: user`. У kind=template/rule отсутствует — body proxy'ится в шаблон/preset на build. |

**Order:** массив сохраняет порядок. Builder идёт линейно сверху вниз — порядок матчинга sing-box (first-match-wins внутри `dns.rules`).

**Identifier matching:**
- `kind: template, title: "X"` — builder ищет в `template.dnsOptions.rules` правило с `title == "X"`. Если нет — orphan.
- `kind: rule, presetId: "Y"` — builder ищет body в `presetDnsRulesByPresetId["Y"]` (заполняется `applyPresetBundles` при expansion). Если нет — orphan. UI рендерит human-readable title через `template.selectableRules.firstWhere((p) => p.presetId == "Y").label`.

**Почему `presetId` а не `title==label`** (§032 fix): label человеко-читаем и mutable (rebrand / локализация / косметика → ломает orphan cleanup для всех юзеров). `preset_id` — technical id, immutable между релизами. Идентификатор симметричен `custom_rules[i].kind: preset` где тоже хранится `presetId`.

### Orphan cleanup

При **сохранении** storage (после reorder, toggle, edit, и т.д.):
- Для каждой записи `type: template` — если в текущем шаблоне нет правила с таким title → запись выбрасывается.
- Для каждой записи `type: rule` — если в активных пресетах нет такого preset.label с `dns_rule` → запись выбрасывается.
- `type: user` никогда не выбрасывается (юзер сам владеет).

Orphan может появиться при апгрейде шаблона (template-default переименован/удалён), отключении пресета, удалении preset из subscription. Cleanup срабатывает при любом write — то есть при первом же `_save()` после изменений UI.

### Auto-discovery

При **загрузке** `DnsSettingsScreen` (и при `applyCustomDns` тоже, как safety-net):
- Для каждого правила в `template.dnsOptions.rules`, у которого нет соответствующей записи в storage с `type: template` и матчащим title → добавляется новая запись `{enabled: <template's enabled_default ?? true>, type: template, title: ...}` **в конец** массива.
- Для каждого активного пресета с непустым `dns_rule`, у которого нет соответствующей записи в storage с `type: rule, title: <preset.label>` → добавляется новая запись `{enabled: true, type: rule, title: <preset.label>}` **в конец** массива.

Юзер потом может перетащить новые записи куда хочет.

### Первый запуск (storage пуст)

Если `dns_options.rules` отсутствует или пустой — auto-discovery выше создаёт начальный набор: все template-defaults + все preset-rules в порядке, заданном шаблоном/конфигом пресетов. UI не показывает пустой экран.

---

## Изменения в `wizard_template.json`

### 1. Поле `title` у каждого DNS-правила в template defaults

Текущее (анонимные правила):
```jsonc
"dns_options": {
  "servers": [...],
  "rules": [
    {"server": "google_doh"}
  ]
}
```

Новое:
```jsonc
"dns_options": {
  "servers": [...],
  "rules": [
    {
      "title": "Default → Google DoH",
      "enabled_default": true,
      "server": "google_doh"
    }
  ]
}
```

`title` — обязательное непустое строковое поле, уникальное в пределах массива. `enabled_default` — опциональное (по умолчанию `true`), копируется в storage при auto-discovery.

В UI builder вычищает wizard-only поля (`title`, `enabled_default`) перед записью в финальный `dns.rules` — sing-box их не понимает.

### 2. Поле `title` у preset's `dns_rule` — НЕ нужно

Title для `type: rule` берётся из `SelectableRule.label`, который уже есть в шаблоне (это label пресета в UI). Поле `dns_rule` остаётся как `{rule_set, server}` без изменений. Если у пресета нет `label` (теоретически возможно по схеме) — preset не получит DNS rule в storage; но это уже broken-state пресета.

---

## Изменения в storage (`SettingsStorage`)

### Новые методы

```dart
/// Read current DNS rules list. List<Map>; каждая запись — `{enabled, type, title, rule?}`.
static Future<List<Map<String, dynamic>>> getDnsRulesList() async { ... }

/// Save DNS rules list (после toggle / reorder / edit / orphan-cleanup).
static Future<void> saveDnsRulesList(List<Map<String, dynamic>> rules) async { ... }
```

### Старые методы — статус

- `getDnsRules() : Future<String>` — пометить `@Deprecated`, оставить для чтения legacy. Builder и UI больше не зовут.
- `saveDnsRules(String)` — пометить `@Deprecated`, оставить (никто не зовёт после рефактора, но не ломаем API).

Поле `dns_options.rules_json` в JSON-файле остаётся (legacy, не удаляем — на случай downgrade пользователя). Новое поле — `dns_options.rules` (структурированное, не путать с legacy `rules_json`).

---

## Изменения в builder (`applyCustomDns`)

### До

```dart
final userRulesJson = await SettingsStorage.getDnsRules();
if (userRulesJson.isNotEmpty) {
  // Полный override: игнорим extraRules от пресетов
  dns['rules'] = jsonDecode(userRulesJson);
} else {
  // template defaults + preset extraRules
  dns['rules'] = [...extraRules, ...templateRules];
}
```

### После

```dart
// Снимаем актуальные template defaults и preset dns_rules
final templateRulesByTitle = <String, Map<String, dynamic>>{
  for (final r in templateDnsRules)
    if (r['title'] is String) r['title']: r,
};
final presetRulesByLabel = <String, Map<String, dynamic>>{
  for (final p in activePresetsWithDnsRule)
    p.label: p.expandedDnsRule,
};

// Auto-discovery: добавляем недостающие записи в storage
final userList = await SettingsStorage.getDnsRulesList();
final discoveredList = _discoverNew(userList, templateRulesByTitle, presetRulesByLabel);
if (discoveredList != userList) {
  await SettingsStorage.saveDnsRulesList(discoveredList);
}

// Сборка финальных правил
final outRules = <Map<String, dynamic>>[];
for (final entry in discoveredList) {
  if (entry['enabled'] != true) continue;
  final type = entry['type'] as String?;
  final title = entry['title'] as String?;
  if (title == null || title.isEmpty) continue;

  Map<String, dynamic>? body;
  if (type == 'user') {
    body = entry['rule'] as Map<String, dynamic>?;
  } else if (type == 'template') {
    final t = templateRulesByTitle[title];
    if (t != null) {
      body = Map<String, dynamic>.from(t)
        ..remove('title')
        ..remove('enabled_default');
    }
  } else if (type == 'rule') {
    body = presetRulesByLabel[title];
  }
  if (body != null) outRules.add(body);
}
dns['rules'] = outRules;
```

**Ключевое отличие:** preset's `dns_rule` теперь представлен явной записью `{type: rule, title: "<preset.label>"}` в `dns_options.rules`, а не неявно инжектится из `extraRules`. Юзер контролирует через UI: оставить, выключить, перетащить.

### Изменения в `applyPresetBundles`

Возвращает `extraDnsRules` как было — но это теперь **map by preset.label**, не плоский список. Подписывается контракт:

```dart
class PresetApplyResult {
  // ...
  final Map<String, Map<String, dynamic>> dnsRulesByPresetLabel;
  // extraDnsRules: List<Map> — оставляем для совместимости, но builder его не использует
}
```

Поскольку и `applyCustomDns`, и `applyPresetBundles` живут в `post_steps.dart` и вызываются из одного места `build_config.dart` — этот контракт internal, можно менять без extern impact.

---

## Изменения в UI (`DnsSettingsScreen`)

### Текущее (после `_load`)

- Список серверов с individual toggle (✅ остаётся).
- TextField с raw JSON массивом для rules (❌ убираем).

### Новое

Под текущей секцией "DNS Servers" — секция "DNS Rules":

```
DNS Rules                                     [+ Add user rule]

══════════════════════════════════════════════════════════════
[≡] [✓] RU domains → Yandex                          [from preset]
        ru-direct · server: yandex_doh
[≡] [✗] Block ads → reject                           [from preset]
        block-ads · server: dns_block
[≡] [✓] Default → Google DoH                         [from template]
        server: google_doh
[≡] [✓] My Cloudflare                                [user]
        domain: example.com · server: cloudflare_doh   [✏] [🗑]
══════════════════════════════════════════════════════════════
```

**Каждая карточка:**
- `[≡]` drag-handle (reorder через `ReorderableListView` сквозь все типы)
- `[✓/✗]` switch — toggle `enabled`
- Title (жирный)
- Subtitle: тип источника (`from preset` / `from template` / `user`) + краткое содержимое (rule_set/domain/server)
- `[✏][🗑]` — только для `user`. Edit открывает JSON-bottom-sheet (как у серверов сейчас); delete снимает запись.

**Add user rule:** кнопка "+ Add user rule" → bottom-sheet с двумя полями:
1. Title (text)
2. Rule body (JSON, monospace, с подсказкой `{"rule_set": "...", "server": "..."}`)

Save валидирует: title непустой, rule — валидный JSON-объект, есть хотя бы одно из `server`/`outbound`/`action`. Save добавляет запись в **конец** массива.

**Reorder:** через `ReorderableListView`. После reorder — `_scheduleSave()`. Никаких ограничений "template только наверху" — юзер свободен.

### Удалённое

- TextField с raw JSON массивом (236-252) — больше не нужен.

### Сохранение — orphan cleanup

`_save()` вызывает `SettingsStorage.saveDnsRulesList(rules)`. В `saveDnsRulesList` (или в самом UI перед вызовом — TBD при имплементации) делается orphan cleanup: записи с `type: template/rule` чьи titles не находятся в текущих template defaults / active presets — выбрасываются. У `type: user` никаких ограничений.

---

## Test plan

1. **Smoke (свежая установка):** `dns_options.rules` нет в storage → открыть DnsSettings → видим template-defaults + preset-rules с дефолтным enabled. Закрываем, перезапускаем app → состояние сохранено.
2. **Toggle:** включить/выключить template-default → applyCustomDns пропускает выключенный → в финальном конфиге его нет.
3. **Toggle preset rule:** выключить `RU domains` → в финальном конфиге `dns.rules` не содержит rule_set: ru-domains. Включить обратно → появилось.
4. **Reorder:** перетащить user rule выше всех → в финальном `dns.rules` он первый → first-match-wins срабатывает на нём.
5. **Add user rule:** добавить `{rule_set: "geoip-ru", server: "yandex_doh"}` с title "RU IPs" → enabled, в финальном конфиге.
6. **Edit user rule:** изменить server → перестроить конфиг → новое значение в финальном.
7. **Delete user rule:** удалить → в storage нет, в финальном конфиге нет.
8. **Apply preset → discovery:** включить новый preset с `dns_rule` → re-open DnsSettings → новая запись в конце списка с enabled=true.
9. **Disable preset → orphan:** выключить preset через RoutingScreen → re-open DnsSettings → запись для этого preset выброшена.
10. **Template upgrade simulation:** в `wizard_template.json` поменять `title` у одного default-rule (или удалить его) → re-open DnsSettings → старая запись выброшена, новая (если переименован) появилась.
11. **Legacy rules_json migration check:** свежая установка → старая версия → юзер сохранил `rules_json`. Обновляем app до новой версии → DnsSettings показывает auto-discovered defaults+presets, `rules_json` игнорируется (но ещё в файле — downgrade-friendly).
12. **Builder integration:** `flutter test` для `applyCustomDns` — все existing тесты проходят с новой моделью.

## Verification

После имплементации:
1. Включить preset `ru-direct` → DnsSettings показывает запись `{type: rule, title: "RU domains direct", enabled: true}`.
2. Build config → `dns.rules` содержит `{rule_set: "ru-domains", server: "yandex_doh"}`.
3. Подключиться к VPN → `dig yandex.ru @127.0.0.1` идёт через yandex_doh (видно в логах sing-box: `query yandex.ru via yandex_doh`).
4. Снять preset → запись становится orphan и выбрасывается при следующем save.

## Risks

| Риск | Митигация |
|---|---|
| Юзер потерял старый `rules_json` | Legacy-поле остаётся в файле; при критической проблеме — manual recovery через JSON-edit. UI этого не закрывает, но и не уничтожает. |
| Title-collision: два template-default с одинаковым `title` | Не валидно по дизайну. Linter check в template loader: дубли = warning (тест в test/). |
| `type: rule` коллизия с user `title` | Рисуются как разные записи (разные `type`); UI и builder не путают. |
| Перформанс: orphan cleanup на каждом save | Linear scan на ~10 записей, тривиально. |
| Race: применили preset → DnsSettings не перечитал → пользователь не видит новое правило | Auto-discovery в `applyCustomDns` тоже добавляет недостающие записи (safety-net): следующий build config починит state. UI rebuild при `route` тоже подходит — RoutingScreen уже инвалидирует config. |

## План имплементации

1. Шаблон: `wizard_template.json` — добавить `title` + `enabled_default` каждому DNS-rule в `dns_options.rules`.
2. Storage: `getDnsRulesList()` / `saveDnsRulesList()` методы; `getDnsRules()` deprecate.
3. Builder: новая логика в `applyCustomDns` (template + preset by-label maps + auto-discovery + linear walk).
4. UI: `DnsSettingsScreen` — `ReorderableListView` секция вместо `TextField`, AddUserRule bottom-sheet, edit/delete для user.
5. Тесты: обновить существующие unit-тесты `applyCustomDns`, добавить тесты на orphan cleanup и auto-discovery.
6. `flutter analyze`, `flutter test`.
7. Build APK + smoke на телефоне (ru-direct preset → конфиг содержит DNS rule → yandex.ru резолвится через yandex_doh).
