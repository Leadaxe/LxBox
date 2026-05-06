# 032 — DNS rules schema symmetry: `type → kind`, `title → presetId` для preset-источника

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-05-02 |
| Связанные spec'ы | [`041 dns rules refactor`](../features/041%20dns%20rules%20refactor/spec.md), [`033 preset bundles`](../features/033%20preset%20bundles/spec.md), [`030 custom routing rules`](../features/030%20custom%20routing%20rules/spec.md) |

## Цель

Убрать асимметрию между `custom_rules` и `dns_options.rules` в storage:

1. **Discriminator field name.** В `custom_rules` discriminator называется `kind` (`inline`/`srs`/`preset`), в `dns_options.rules` — `type` (`user`/`template`/`rule`). Один и тот же концепт — sealed-discriminator — называется по-разному. Привести к единому `kind`.

2. **Pointer на preset.** В `custom_rules[i].kind == 'preset'` хранится `presetId` — immutable technical id. В `dns_options.rules[i].type == 'rule'` (после §041) хранится `title == <preset.label>` — **mutable** human-readable label. Это:
   - ломается при локализации label'ов в шаблоне (rebrand → orphan'ы у юзеров)
   - ломается при rename пресета между релизами
   - даёт ambiguity если два пресета с одинаковым label
   - заставляет код знать про два разных id'а одного объекта

   Привести к симметрии: для `kind: rule` хранить `presetId`, как в `custom_rules`.

§041 ещё не разлетелось у юзеров (только локально на dev-телефоне), миграция дешёвая и предсказуемая. **Окно для cleanup'а — сейчас.**

## Не в скопе

- **Servers symmetry** — у `dns_options.servers` нет discriminator вообще (preset-инжектируемые серверы не персистятся). Это отдельная фича (per-server enable из preset → значимо больше работы), отдельной таской.
- **Rename `kind` → `node_kind`** — обсуждалось, оставляем `kind` (k8s/Dart-конвенция, k8s + Dart sealed уже использует `kind`, не вводим лишнее переименование уже-shipped поля в `custom_rules`).
- **`type` в `dns_options.servers`** (= sing-box DNS protocol: `udp`/`https`/`tls`) — НЕ трогаем, это sing-box-нативное поле.

## Изменения в storage shape

### До (текущее §041)

```jsonc
"dns_options": {
  "rules": [
    {"enabled": true, "type": "rule",     "title": "Russian domains direct"},
    {"enabled": true, "type": "template", "title": "Default → Google DoH"},
    {"enabled": true, "type": "user",     "title": "My CF",
     "rule": {"server": "cloudflare_doh"}}
  ]
}
```

### После

```jsonc
"dns_options": {
  "rules": [
    {"enabled": true, "kind": "rule",     "presetId": "ru-direct"},
    {"enabled": true, "kind": "template", "title": "Default → Google DoH"},
    {"enabled": true, "kind": "user",     "title": "My CF",
     "rule": {"server": "cloudflare_doh"}}
  ]
}
```

| `kind` | Identifier field | Семантика identifier |
|---|---|---|
| `user`     | `title`    | freeform, юзер задал в UI; идентифицирует сам себя |
| `template` | `title`    | строгое совпадение с `wizard_template.json/dns_options.rules[i].title` (template-controlled, immutable между релизами без code-change) |
| `rule`     | `presetId` | строгое совпадение с `wizard_template.json/selectable_rules[i].preset_id` (immutable technical id) |

**`title` для `kind: rule` рендерится в UI динамически** через `template.selectableRules.firstWhere((p) => p.presetId == entry.presetId).label`. В storage не хранится.

## Изменения в коде

### `SettingsStorage` — миграция

Один проход в `resolveDnsRulesList` при load. Псевдокод:

```dart
final stored = await SettingsStorage.getDnsRulesList();
var migrated = false;
final fixed = <Map<String, dynamic>>[];
for (final raw in stored) {
  final entry = Map<String, dynamic>.from(raw);
  // 1. type → kind
  if (entry.containsKey('type') && !entry.containsKey('kind')) {
    entry['kind'] = entry.remove('type');
    migrated = true;
  }
  // 2. title → presetId для kind=rule
  if (entry['kind'] == 'rule'
      && entry.containsKey('title')
      && !entry.containsKey('presetId')) {
    final label = entry['title'] as String?;
    final preset = template.selectableRules
        .where((p) => p.label == label)
        .firstOrNull;
    if (preset != null) {
      entry['presetId'] = preset.presetId;
      entry.remove('title');
      migrated = true;
    }
    // else: orphan, отсев на cleanup ниже
  }
  fixed.add(entry);
}
if (migrated) {
  // saveDnsRulesList сразу — UI на следующем _load увидит новый shape
}
```

Миграция **идемпотентна:** второй проход уже видит `kind` + `presetId` и ничего не делает.

Старые поля (`type`, `title` для kind=rule) **не оставляем** в storage — переименование, не дублирование. Юзер не должен иметь stale данные после upgrade.

### `resolveDnsRulesList`

Изменения:
- Map `presetDnsRulesByLabel: Map<String, Map>` → `presetDnsRulesByPresetId: Map<String, Map>`. Лучше переименовать чтобы code self-documented.
- Comparison: `e['kind'] == 'rule' && presetDnsRulesByPresetId.containsKey(e['presetId'])`
- Auto-discovery новых пресетов: `{enabled: true, kind: 'rule', presetId: <pid>}` без `title`.

### `applyCustomDns`

- Параметр `extraDnsRulesByPresetLabel` → `extraDnsRulesByPresetId`.
- Resolve `kind: rule` через `presetId` lookup.

### `applyPresetBundles`

- Поле `dnsRulesByPresetLabel` → `dnsRulesByPresetId` в `PresetApplyResult`.
- Заполняется как `dnsRulesByPresetId[match.presetId] = fragments.dnsRule`.

### `DnsSettingsScreen`

- `_presetRulesByLabel` → `_presetRulesByPresetId: Map<String, Map>`
- Дополнительно `_presetLabelByPresetId: Map<String, String>` для рендера title'а row'ы (`title: <label>` динамически).
- В UI tile для `kind: rule`: title тянется через `_presetLabelByPresetId[entry['presetId']] ?? entry['presetId']` (fallback на presetId если preset вдруг исчез между load и render).

### Тесты

Все тесты в `test/services/builder/dns_rules_resolver_test.dart` переписать:
- `'type': 'user'` → `'kind': 'user'`
- `'type': 'rule'`, `'title': 'X'` → `'kind': 'rule'`, `'presetId': 'X'` (где X это presetId, не label)
- Контракт `extraDnsRulesByPresetLabel` → `extraDnsRulesByPresetId`

Дополнить **новый migration test:**
- Storage с legacy shape `{type, title}` для kind=rule → после `resolveDnsRulesList` storage имеет `{kind, presetId}`.
- Storage с legacy `{type: template, title}` → `{kind: template, title}` (только rename type→kind).

## Реализация

1. **Storage migration** в `resolveDnsRulesList` — psuedo-code выше.
2. **Builder + UI** — поиск-замена по `'type'` / `'title'` в DNS-rules-related местах + переименование map'ов.
3. **Spec 041** обновить (docs/spec/features/041 dns rules refactor/spec.md) — новые shape примеры в Storage section, новые тесты в Test plan.
4. **Тесты** — переписать unit-тесты + добавить migration-тесты.
5. `flutter analyze` + `flutter test` (целый suite).
6. **Build APK + install via wifi-adb** — проверить что storage на тестовом телефоне (где уже §041) мигрировался корректно (открыть DnsSettings → видим preset-rule под старым label, но в storage под presetId).

## Verification

После имплементации, на тестовом телефоне:
1. Storage до апдейта: `dns_options.rules` имеет `{type: rule, title: "Russian domains direct"}` от §041 build'а.
2. Поставить новый APK → открыть DnsSettings (триггерит `_load` → `resolveDnsRulesList` → migration).
3. Через `/state/storage` Debug API увидеть: `{kind: rule, presetId: "ru-direct"}`. Title больше не лежит в storage.
4. UI всё ещё рендерит "Russian domains direct" — тянется из `template.selectableRules`.
5. Toggle/reorder/orphan/auto-discovery — все работают как и раньше.
6. Edge: симулировать переименование label'а в шаблоне (вручную поменять в `wizard_template.json` `"label": "Russian domains direct"` → `"RU domains (direct mode)"`, hot-restart) → user storage **не теряет** правило (presetId стабилен), UI просто покажет новый label.

## Risks

| Риск | Митигация |
|---|---|
| Storage юзера в проде уже имеет старую §041 shape (актуально пока только для dev-телефона) | Idempotent migration, проверена тестом и на реальном storage |
| `presetId` пустой у preset (corrupted template) → миграция не находит match | Запись остаётся с `title`, но без `presetId` — на cleanup отсев в orphan. Юзер видит исчезнувшее правило, может вручную пере-включить через RoutingScreen |
| Кто-то backup'ил storage от §041-без-cleanup'а | Restore через Debug API `/backup/import` тоже триггерит migration на следующем load (проходит через `resolveDnsRulesList`) |
| Field rename ломает CI / build pipelines | Нет CI-зависимостей на `type` field — поиск-замена внутри Dart-кода, тесты переписаны, public API stable |

## Что НЕ в скопе этой таски

- Симметризация `dns_options.servers` (отдельная feature task: per-server enable из preset).
- Migration `custom_rules.kind` → `node_kind` (отказались, оставляем `kind` для конвенции).
- UI improvements (это чисто schema cleanup).
