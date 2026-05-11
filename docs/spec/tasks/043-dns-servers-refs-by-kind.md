# 043 — DNS servers as kind-discriminated refs (симметрия с DNS rules)

| Поле | Значение |
|------|----------|
| Статус | Released (v1.6.1) |
| Дата | 2026-05-07 |
| Связанные spec'ы | [`014 dns settings`](../features/014%20dns%20settings/spec.md), [`033 preset bundles`](../features/033%20preset%20bundles/spec.md), [`tasks/061-dns-rules-refactor`](061-dns-rules-refactor/spec.md) (был §041), [`042 dns servers merge`](./042-dns-servers-merge-and-cleanup.md) — заменяется этой задачей |
| Затронутые файлы | `app/lib/services/settings_storage.dart`, `app/lib/services/builder/post_steps.dart`, `app/lib/services/builder/build_config.dart`, `app/lib/screens/dns_settings_screen.dart`, `app/lib/services/debug/handlers/settings.dart`, тесты |

## Цель

Привести `dns_options.servers` storage schema к **точно той же** kind-discriminated архитектуре что и `dns_options.rules` (§061 dns-rules-refactor, бывший feature §041). Это убирает три класса багов разом (см. live-наблюдения в [§042](./042-dns-servers-merge-and-cleanup.md)):

1. **Stale fields** — storage хранил полный snapshot template-сервера; при template-обновлении (rename, body change) shape становился неактуальным, а в config попадал устаревший body. Видно после §039 (`direct_dns_resolver` → `google_udp`): old user-saved snapshot ссылался на удалённый tag.
2. **Override-detection через shape comparison** — order-sensitive `jsonEncode`, требует strip mutable, проблемы с nested maps. Ненадёжно.
3. **Длинные badge'и** — «User (overrides template)» / «Preset · Russian domains direct» ломали title-wrap в UI.

§042 пытался полу-решить через 3-tier merge с shape-comparison-based override detection. Это работало частично, но архитектурно не симметрично с §061 DNS rules (бывший feature §041). Заменяем на refs-by-kind.

## Schema (storage)

Симметрично `dns_options.rules` (§061, бывший feature §041):

```json
"dns_options": {
  "servers": [
    {"enabled": true,  "kind": "template", "tag": "google_doh"},
    {"enabled": false, "kind": "template", "tag": "cloudflare_dot"},
    {"enabled": true,  "kind": "preset",   "tag": "yandex_udp"},
    {"enabled": true,  "kind": "inline",   "tag": "my-custom-doh",
                                           "body": {"type":"https","tag":"my-custom-doh","server":"...",...}}
  ]
}
```

### Поля

| Поле | Обязательно для | Описание |
|---|---|---|
| `enabled` | все kind'ы | per-user toggle (default `true` для inline, наследует из template/preset для соотв. kind'ов на auto-discovery) |
| `kind` | все | `inline` \| `preset` \| `template` |
| `tag` | все | unique identifier; для template/preset — lookup-key, для inline — собственный ID |
| `body` | **только** `kind: inline` | full sing-box server body (тот же shape что сейчас в storage) |

Для `kind: template` / `preset` body **не хранится** — берётся из template / active preset's `dns_servers` по tag'у at render/build time.

## Поведение

### Render (UI / dropdown'ы)

Resolver `resolveDnsServersList` (по образцу `resolveDnsRulesList` из §061, бывший feature §041):

```
walk storage:
  if kind == 'template':
    body = templateByTag[entry.tag]
    if body == null: drop (orphan)
    yield {body, enabled: entry.enabled, _origin: 'template'}
  elif kind == 'preset':
    body = presetByTag[entry.tag]
    if body == null: drop (orphan, preset deactivated)
    yield {body, enabled: entry.enabled, _origin: 'preset'}
  elif kind == 'inline':
    yield {entry.body, enabled: entry.enabled, _origin: 'inline',
           _was: tag in template ? 'template' : (tag in preset ? 'preset' : 'user')}
```

`_was` annotation — для UI: показывает что инлайн перекрывает (если вообще что-то).

### Auto-discovery (на load)

Walk template'овские servers + active preset'ы; для каждого tag'а которого нет в storage — append:

```dart
{'enabled': tplEntry?.enabled ?? true, 'kind': 'template', 'tag': X}
{'enabled': true,                      'kind': 'preset',   'tag': X}
```

Persist если что-то изменилось.

### Orphan cleanup (на load)

Для каждой entry в storage:
- `kind: template, tag: X` → если `templateByTag[X]` null → drop
- `kind: preset, tag: X` → если ни один active preset не содержит X → drop
- `kind: inline` → keep (user-defined)

### UI transitions

| Действие | Storage transition |
|---|---|
| Toggle enabled (любой kind) | Update `enabled`, kind не меняется |
| Edit body на template/preset entry | `kind: template/preset` → `kind: inline` + `body` (= edited body); template/preset overlay для этого tag'а пропадает |
| Reset на inline-override (tag совпадает с canonical) | `kind: inline` → `kind: template` (или `preset`), `body` field удалён |
| Add custom server | Append `{kind: 'inline', tag: <user-input>, body: <user JSON>, enabled: true}` |
| Delete inline (no canonical) | Remove entry entirely |
| Delete inline (overrides canonical) | Equivalent to Reset — remove inline, kind возвращается на canonical через auto-discovery |

### Badge'и (сразу решает «длинные чипы»)

| Storage entry | Badge |
|---|---|
| `kind: template` | **Template** |
| `kind: preset` | **Preset** (плюс preset-label в subtitle) |
| `kind: inline`, tag нет в canonical | **User** |
| `kind: inline`, tag есть в canonical | **Overridden** |

Все односложные. Никаких «User overrides template» — overridden = inline + canonical exists.

## Builder consequences (`build_config.dart`)

Сейчас builder читает `_servers` напрямую как list of bodies, дедуп по tag (first-wins). После refactor'а — нужен резолв через resolver:

```dart
final resolved = resolveDnsServersListBodies(
  storage: settings.dnsServers,
  templateServers: templateServersRaw,
  presetServers: presetServersByTag,  // { tag → expanded body } из active preset'ов
);
// resolved — list<Map> готовых sing-box server-bodies, отфильтрованных по `enabled`
config['dns']['servers'] = resolved;
```

## Migration (one-shot)

Существующие юзеры v1.6.0 (или раньше) имеют storage с full-body snapshots. На первый `_load()` после установки v1.6.x с этой задачей — auto-detect и migrate:

```dart
List<Map<String, dynamic>> migrateLegacyServers(
  List<Map<String, dynamic>> raw,
  Map<String, Map<String, dynamic>> templateByTag,
  Map<String, Map<String, dynamic>> presetByTag,
) {
  if (raw.isEmpty || raw.every((s) => s.containsKey('kind'))) return raw;
  final out = <Map<String, dynamic>>[];
  for (final s in raw) {
    final tag = s['tag']?.toString();
    if (tag == null || tag.isEmpty) continue;
    final tpl = templateByTag[tag];
    final preset = presetByTag[tag];
    final canonical = tpl ?? preset;
    final enabled = s['enabled'] != false;
    if (canonical == null) {
      // Pure custom
      out.add({'enabled': enabled, 'kind': 'inline', 'tag': tag, 'body': s});
    } else if (DeepCollectionEquality().equals(_strip(s), _strip(canonical))) {
      // Snapshot of canonical (только enabled может отличаться) — конвертируем в ref
      out.add({'enabled': enabled, 'kind': tpl != null ? 'template' : 'preset', 'tag': tag});
    } else {
      // Real override — keep как inline с full body
      out.add({'enabled': enabled, 'kind': 'inline', 'tag': tag, 'body': s});
    }
  }
  return out;
}
```

Save migrated state. Дальше — обычный flow.

`_strip(m)` убирает `enabled`/`description`/UI-аннотации перед сравнением.

## Debug API

`PUT /settings/dns_options/servers` — schema принимает оба формата:
- Legacy (full body list) → auto-migrate в kind-refs перед save'ом.
- New (kind-refs list) → save as is.

Detection: если в первом элементе есть поле `kind` — new format; иначе — legacy.

## Tests

- `test/services/builder/dns_servers_resolver_test.dart`:
  1. orphan cleanup: `kind: template, tag: deleted` → drop.
  2. orphan cleanup: `kind: preset, tag: not-in-active-preset` → drop.
  3. auto-discovery: empty storage → populated с template + active preset entries.
  4. resolved bodies: kind=template → template body; kind=preset → preset body; kind=inline → entry.body.
  5. enabled filter: disabled entries не в final config.
- `test/services/dns_servers_migration_test.dart`:
  1. legacy snapshot identical to template → конвертируется в `kind: template` ref.
  2. legacy snapshot с different shape → конвертируется в `kind: inline` с body.
  3. legacy entry с tag не в canonical → `kind: inline` (pure user).
  4. already-migrated storage (есть `kind`) → no-op.
- Widget tests на `dns_settings_screen` — все 4 badge'а отображаются для соотв. storage entries; Reset transition работает.

## Acceptance

- [ ] Schema migration при первом `_load()` после установки: legacy snapshots → kind-refs. Storage сжимается в разы.
- [ ] **Template tag rename**: после §039-style rename'а (`direct_dns_resolver` → `google_udp`), existing user storage'ы автоматически очищаются — старый tag получает orphan-cleanup, новый tag добавляется auto-discovery.
- [ ] **Toggle enabled на template-сервере** не превращает его в `kind: inline` (только `enabled` меняется, kind остаётся `template`). Badge остаётся `Template`.
- [ ] **Edit body на template-сервере** переводит entry в `kind: inline` + body. Badge становится `Overridden`. Reset кнопка появляется.
- [ ] **Reset на inline-override** возвращает `kind: template` (или `preset`), body удалён. Badge становится `Template` / `Preset`.
- [ ] **Add custom inline-сервер** — `kind: inline`, badge `User`. Delete удаляет entry.
- [ ] **Builder** строит config с правильными bodies через resolver; sing-box reload — successful.
- [ ] **Debug API `PUT /settings/dns_options/servers`** принимает оба формата (legacy + new), legacy auto-converts.
- [ ] DNS Settings dropdown'ы (DNS Final / Default Resolver / per-rule) видят union'ы tag'ов из всех source'ов.
- [ ] **Badge text короткий**: `Template`, `Preset`, `User`, `Overridden`. Title в tile никогда не wrap'ит из-за длинного badge'а.

## Не в скопе

- **Per-tile reordering** drag'ом — не симметрично с DNS rules где этот UX уже есть. Можно добавить отдельной задачей.
- **Validation** body-shape'а на client side — sing-box сам ругнёт при reload'е; client-side validation отдельная задача.
- **i18n** badge'ей — text-only, локализация когда вся app переведётся.

## Risks

| Риск | Mitigation |
|---|---|
| Migration портит existing data | Migration сохраняет ВСЕ данные: либо как ref (если matches canonical), либо как inline с full body (если override). Lossless. |
| Preset deactivation удаляет user'ы данные? | `kind: preset` — это per-user enabled-state, не данные. Если preset deactivated → orphan cleanup убирает entry; но если юзер хотел кастомизировать — он бы изначально сделал `kind: inline` с body. Логично. |
| Builder rebuild не идёт сразу после migration | Migration лишь чинит storage shape; builder вызывается отдельно (rebuild-config). На первый rebuild после migration config соберётся с актуальными bodies — то что и должно быть. |
| Debug API breaking change для старых curl-скриптов | Принимаем оба формата (auto-detect по `kind` field). Adb-скрипты работают как раньше. |

## План имплементации

1. **`settings_storage.dart`** — `migrateLegacyDnsServers()` helper (вызывается из `_load`); existing get/save methods оставляем (хранят как есть).
2. **`builder/post_steps.dart`** — `resolveDnsServersList()` (auto-discovery + orphan cleanup, persist if changed); `resolveDnsServersBodies()` (resolves to full bodies для builder'а).
3. **`builder/build_config.dart`** — заменить direct usage `dnsServers` на `resolveDnsServersBodies(...)`.
4. **`screens/dns_settings_screen.dart`** — `_load` зовёт migration + resolveDnsServersList; render через resolved list; edit handlers — kind transitions; короткие badge'и; Reset через kind transition.
5. **`debug/handlers/settings.dart`** — `_putDnsServers`: detect legacy vs new format, конверсия.
6. Tests.
7. `flutter analyze + test + APK + install`.
8. Smoke на устройстве: убедиться что storage migrate'нулся в kind-refs (через `/state/storage`); все 4 badge'а отображаются корректно; Reset transition работает; builder rebuild не ломается.
