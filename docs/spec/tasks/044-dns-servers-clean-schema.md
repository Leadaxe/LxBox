# 044 — DNS servers: clean schema (single-source tag, meta vs body separation)

| Поле | Значение |
|------|----------|
| Статус | Released (v1.6.1) |
| Дата | 2026-05-07 |
| Связанные spec'ы | [`043 dns servers refs by kind`](./043-dns-servers-refs-by-kind.md) — расширяет |
| Затронутые файлы | `app/lib/services/builder/post_steps.dart`, `app/lib/services/builder/build_config.dart`, `app/lib/screens/dns_settings_screen.dart`, `app/lib/services/debug/handlers/settings.dart`, `app/lib/services/debug/serializers/storage.dart`, тесты |

## Цель

Отделить metadata-поля (`description`, `enabled`) от sing-box body, убрать дубликат `tag` (ref-level vs body-level из §043), и заменить underscore-аннотации в render-Map'ах на typed `ResolvedServer`.

Решает три проблемы возникшие в §043:
1. **Magic gluing tag'а** — `dns_options.servers[i].tag` дублирован с `body.tag`. Edit body может рассинхронить → orphan'ит lookup.
2. **`_kind`/`_overrides`/`_preset_label` underscore-поля протекают** в JSON viewer'е (см. live-баг — `_kind` показывается у некоторых entry'ев в `_showServerBodyDialog` потому что забыл strip). Конвенция «не enforced».
3. **`description`/`enabled` смешаны с sing-box body** в edit dialog'е — юзер видит «магические» поля в JSON редакторе.

## Schema (§044 final)

### `lxbox_settings.json.dns_options.servers[i]`

```json
{
  "kind":        "template" | "preset" | "inline",
  "enabled":     <bool>,
  "tag":         <string>,                   // single source of truth
  "description": <string>?,                   // optional override / primary для inline
  "body":        <partial sing-box body>?    // только для kind=inline; БЕЗ tag/description/enabled
}
```

| Поле | Обязательно для | Source-of-truth для |
|---|---|---|
| `kind` | все | UI badge / builder branch |
| `enabled` | все | per-user toggle (не sing-box meta) |
| `tag` | все | single source — синтезируется в body на build-time |
| `description` | inline (primary), template/preset (опционально override) | UI tile title |
| `body` | inline | sing-box server shape, partial (без tag/description/enabled) |

### `wizard_template.json.dns_options.servers[i]` — **flat, не меняется**

```json
{"type": "https", "tag": "google_doh", "server": "dns.google", "server_port": 443, "path": "/dns-query", "description": "Google DoH", "enabled": true}
```

Template остаётся flat (sing-box-convention). На build-time builder копирует canonical → strip `description`/`enabled` (sing-box не использует) → inject `tag` из ref'а.

### `wizard_template.json.selectable_rules[*].dns_servers[i]` — **flat, не меняется**

```json
{"type": "udp", "tag": "yandex_udp", "server": "@dns_ip", "server_port": 53, "detour": "@outbound", "description": "Yandex UDP"}
```

Та же flat-конвенция. После `expandPreset` идёт через тот же resolver-helper.

## Builder synthesis (запротоколированная магия)

### `resolveDnsServersBodies` (refs → final sing-box bodies для `config.dns.servers[i]`)

```
ref.kind == 'inline'    → body = clone(ref.body)               // partial body без tag/description/enabled
ref.kind == 'template'  → body = clone(template[ref.tag])      // full canonical
                          - strip description, enabled, tag
ref.kind == 'preset'    → body = clone(preset[ref.tag])
                          - strip description, enabled, tag

всегда:                   body['tag'] = ref.tag                // synthesize from single source

return body                                                     // готов для config.dns.servers[i]
```

**`description` / `enabled` не synthesizются в финальный sing-box config** — sing-box не использует.

### `resolveResolvedServer` (refs → typed `ResolvedServer` для UI)

```
ref → body (как выше) + ref.description ?? canonical.description ?? ''
                       + ref.enabled
                       + computed: overrides? presetLabel?
return ResolvedServer(...)
```

UI tile читает typed accessors. Никаких underscore-полей.

### Render layer — typed `ResolvedServer`

```dart
class ResolvedServer {
  final ServerKind kind;             // typed enum: template | preset | inline
  final String tag;
  final String description;          // resolved (ref's или canonical's fallback)
  final bool enabled;
  final Map<String, dynamic> body;   // ready-to-display partial sing-box body С injected tag'ом
  final ServerKind? overrides;       // kind canonical'а если ref overrides — иначе null
  final String? presetLabel;         // для preset / overridden-preset
}

enum ServerKind { template, preset, inline }
```

Underscore-аннотации (`_kind`, `_overrides`, `_preset_label`, `_origin`) — **удалены полностью**. UI работает с typed instance.

## Migration (one-shot)

### Detection

| Признак | Версия storage |
|---|---|
| Все entries без поля `kind` | pre-§043 (legacy full-body snapshot) |
| `kind: inline` + `body.tag` существует | §043 (intermediate; tag duplicated, description в body) |
| `kind: inline` + `body.tag` отсутствует | §044 (already migrated) |
| `kind: template/preset` | без изменений (та же форма во всех версиях) |

### Шаги

```dart
for entry in raw_storage:
  if entry.kind == null:
    // Pre-§043 → §044
    classify(entry vs canonical):
      no canonical                 → emit {kind: inline, tag, enabled, description?, body: stripped}
      shape matches canonical      → emit {kind: 'template'/'preset', tag, enabled}
      shape differs from canonical → emit {kind: inline, tag, enabled, description?, body: stripped}
  elif entry.kind == 'inline' and entry.body has tag:
    // §043 → §044
    description = entry.body.description (peel)
    body = entry.body without tag/description/enabled
    emit {kind: inline, tag: entry.tag, enabled, description, body}
  else:
    // already §044 (or template/preset ref) — no-op
    emit entry
```

`stripped` body — copy без `tag`/`description`/`enabled` (peeled).

### Side-effects

- **Lossless** — все user-modifications сохраняются (description / overrides / custom servers).
- **Persists immediately** — после migration storage save'ится; следующий `_load` no-op.
- **Builder rebuild** на следующий config-rebuild — sing-box получает clean shape.

## UI Edit dialog

```
[Edit DNS Server]
┌──────────────────────────────────────┐
│ Tag:          [my-doh           ]    │  ← read-only при edit existing
│ Description:  [My fast DNS      ]    │  ← TextField
│ Enabled:      [●—]                  │  ← Switch
│                                       │
│ Body (sing-box JSON):                │
│ ┌──────────────────────────────────┐ │
│ │ {                                 │ │
│ │   "type": "https",                │ │
│ │   "server": "5.5.5.5",            │ │
│ │   "server_port": 443,             │ │
│ │   "path": "/dns-query"            │ │
│ │ }                                 │ │
│ └──────────────────────────────────┘ │
│                                       │
│             [Save]                    │
└──────────────────────────────────────┘
```

### Validation на save

- `tag` непустой
- Edit existing: `tag` не меняется (locked)
- Edit new: `tag` уникален (нет collision'а с existing entry)
- `body` JSON валидный, **не содержит** `tag` / `description` / `enabled` (если есть — auto-strip + warning)

### Save logic

```dart
// edit body на template/preset → переход в kind: inline
ref = {
  'kind': 'inline',
  'enabled': switchValue,
  'tag': tagInput,
  'description': descriptionInput.isNotEmpty ? descriptionInput : null,
  'body': parsedBody,
};

// edit body на inline → update в place
ref.enabled = switchValue;
ref.description = descriptionInput.isNotEmpty ? descriptionInput : null;
ref.body = parsedBody;

// Override description (на template/preset, не trigger transition в inline) — кнопка «Set custom name»
ref.description = newDescription; // kind остаётся template/preset
```

## Acceptance

- [ ] **Storage shape**: `dns_options.servers[i]` всегда `{kind, enabled, tag, description?, body?}`. Никогда не содержит `tag` / `description` / `enabled` внутри `body`.
- [ ] **Migration**: existing v1.6.1 install → одноразовая конверсия §043 → §044 на следующий `_load`. Lossless. Storage save'ится только если что-то изменилось.
- [ ] **Builder**: `config.dns.servers[i]` имеет `tag` (синтезированный из ref'а), не имеет `description`/`enabled`. Sing-box reload работает.
- [ ] **Edit dialog**: 3 явных input'а (Tag / Description / Enabled) + body JSON без metadata. Валидация tag-uniqueness для new.
- [ ] **Reset на kind: inline**: возвращает к `kind: template/preset`, drops `description` ref-override, drops body.
- [ ] **No underscore поля**: `_showServerBodyDialog` показывает только storage-shape (kind, enabled, tag, description?, body?), никаких UI-аннотаций.
- [ ] **`ResolvedServer` typed class**: render layer заменён, UI tile через typed accessors.

## Не в скопе

- **Override description без conversion в inline** — техника возможна (set ref.description на template/preset entry), но edit dialog для template/preset clean пока не показывает description input — только switch + edit. Если useful — отдельной задачей.
- **Body validation против sing-box schema** — sing-box сам ругнёт при reload'е; client-side schema validation отдельная задача.
- **Drag-handle reorder** для DNS servers — симметрия с rules где это есть, но не блокер для §044.

## План имплементации

1. **`post_steps.dart`**:
   - `resolveDnsServersList`: миграция расширена (§043 → §044 case + sanitize body для inline). Сохраняем storage только если изменилось.
   - `resolveDnsServersBodies`: единый flow inline / template / preset → strip non-sing-box → inject tag. Чистится от прежних strip'ов лишних.
2. **`screens/dns_settings_screen.dart`**:
   - `_displayedServers` returns `List<ResolvedServer>` (typed).
   - `_buildMergedServerTile(ResolvedServer)` — typed accessors, никаких Map[`_kind`].
   - `_showServerBodyDialog`: показывает только storage-shape (без UI-аннотаций; в §044 их физически нет).
   - Edit dialog: 3 input'а + body editor. Save logic — kind transition по нужде.
3. **Underscore cleanup**: удалить все `_origin`/`_kind`/`_overrides`/`_preset_label` из Map-injection'ов в `_displayedServers`.
4. **Storage scrubber** (`debug/serializers/storage.dart`) — обновить под новую schema (description как top-level, body partial).
5. **Tests**:
   - Migration tests: pre-§043 → §044, §043 inline → §044, no-op на already §044.
   - Resolver tests: tag synthesis, description fallback, builder strip.
6. **Documentation**:
   - `docs/api/debug-api-reference.md` — `PUT /settings/dns_options/servers` принимает обе schema (§043 + §044), auto-detect.
   - `docs/ARCHITECTURE.md` — добавить «§044 DNS servers schema».
   - `CHANGELOG.md` — entry в `[Unreleased]` (или v1.6.2 patch).
7. `flutter analyze + test + APK + install`.
