# 063 — Backup format rewrite: single-snapshot, no legacy

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-05-10 |
| Зависимости | [`features/040 backup restore ui`](../features/040%20backup%20restore%20ui/spec.md) — родительская фича; этот task — её v2 wire-format. [§031 debug api](../features/031%20debug%20api/spec.md) (`/backup/*` endpoints). |
| Триггер | Юзер пытается восстановить backup от 10 мая, в котором был inline rule_set «Ru Apps» (57 `package_name`) → выясняется что **в backup'е custom_rules вообще нет**: они хранятся top-level в `lxbox_settings.json`, а `BackupService` ходил только через `getAllVars()` который читает только `data['vars']`. Тот же баг с `tun_apps`, `enabled_groups`, `enabled_rules`, `route_final`, `rule_outbounds`, `dns_options`. Restore терял routing полностью. |

## Цель

Переписать wire-format backup'ов на **полный snapshot `lxbox_settings.json`** — без allowlist'ов ключей. Любой новый top-level ключ автоматически попадает в backup без правок `BackupService`. Native-side VPN system toggles (`boxvpn_boot` SharedPreferences) включить отдельным блоком (Flutter storage их не знает).

Сделать **single-format**, без legacy support: версия `1` reject'ится с понятным message, миграционного path нет.

## Не в скопе

- **Encryption** — backup как был plain JSON, так и остаётся (§040 уже это решил).
- **Migration старых backup'ов** — `version: 1` reject'ится; pre-v1.7.3 пользователи делают новый export после апдейта. Migration tool отдельно никто не просил.
- **Перенос `boxvpn_boot` SharedPreferences в `lxbox_settings.json`** — обсуждалось; отказались, потому что BootReceiver читает at boot-time когда Flutter ещё не запущен. Native side остаётся самостоятельным, backup просто экспортит обе части.
- **Per-server-list selection** — категории остаются all-or-nothing в каждой (§040 V1).
- **Auto-cloud backup** — отдельная фича.

---

## Что было сломано

### Storage layout vs backup expectation

`lxbox_settings.json` имеет top-level ключи:
```
custom_rules, tun_apps, enabled_groups, enabled_rules, presets_migrated,
route_final, rule_outbounds, dns_options, server_lists, vars
ping_options, last_global_update, excluded_nodes, wifi_history (в vars), ...
```

`vars` — это **отдельный nested map**, в который кладутся только plain toggles (`log_level`, `dns_strategy`, `clash_api`, `tun_*`, `urltest_*`, `auto_*`, `last_*`, `debug_*`, …).

`SettingsStorage.getAllVars()` ([settings_storage.dart:86](../../../app/lib/services/settings_storage.dart:86)) возвращал **только `data['vars']`** — то есть весь top-level кроме `vars` оставался невидимым для backup.

### BackupService.buildExport (старая версия)

```dart
final allVars = await SettingsStorage.getAllVars();    // ← только data['vars']
final filteredVars = _filterVars(allVars, ...);       // routing-keys filter
out['vars'] = filteredVars;
```

`_routingKeys = {'custom_rules', 'route_final'}` — этот allowlist **никогда не срабатывал**, потому что `custom_rules` и `route_final` находились **не в `vars`**, а на корне. Один `server_lists` экспортился отдельно (он top-level, getServerLists() отдельный метод). Всё остальное — терялось.

### parseImport / applyImport (старая версия)

Симметрично: парсил `decoded['vars']` и распределял по категориям через тот же `_routingKeys`. Top-level `decoded['custom_rules']` / `decoded['tun_apps']` парсер не читал. Restore из любого backup'а возвращал только server_lists + (часть) vars.

### Real-world impact

Backup от 10 мая (`lxbox-backup-20260510-135255.json` на устройстве):
- `vars` content — 30 ключей, **`custom_rules` отсутствует**
- `config.route.rule_set` имел inline tag `"Ru Apps"` с 57 `package_name` (Tinkoff, Yandex, Gosuslugi, VK, Avito, …)
- При попытке восстановить через UI Restore — `BackupService.parseImport` не находит `custom_rules` нигде → routing tab остаётся пустым

### Дополнительная проблема

Native-side VPN system toggles живут в **`boxvpn_boot` SharedPreferences** ([BootReceiver.kt](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BootReceiver.kt)) — это отдельный файл `/data/data/com.leadaxe.lxbox/shared_prefs/boxvpn_boot.xml`, не часть `lxbox_settings.json`. 5 toggles (`auto_start_vpn`, `keep_vpn_on_exit`, `background_mode`, `core_logs_enabled`, `allow_bypass`) **никогда не были в backup**. Это §052 surface — после переноса VPN System tab настроек в UI прыгающий gap'.

---

## Новый wire-format

```json
{
  "app": "lxbox",
  "kind": "backup",
  "created_at": "2026-05-10T19:23:45Z",
  "source_app_version": "1.7.3+32",
  "storage": {
    "vars": { ... },
    "server_lists": [ ... ],
    "custom_rules": [ ... ],
    "tun_apps": { mode, packages },
    "enabled_groups": [ ... ],
    "enabled_rules": [ ... ],
    "route_final": "...",
    "rule_outbounds": { ... },
    "dns_options": { ... },
    "ping_options": { ... },
    ...все остальные top-level ключи lxbox_settings.json
  },
  "vpn_settings": {
    "auto_start": false,
    "keep_on_exit": false,
    "background_mode": "never|lazy|always",
    "core_logs_enabled": false,
    "allow_bypass": false
  }
}
```

**Markers**:
- `app == "lxbox"` + `kind == "backup"` — file detection
- `storage` обязателен (наличие = новый формат); отсутствие = legacy → reject

**`version` поле убрано** сознательно. Single format. Если когда-нибудь breaking schema change нужен — добавим `version: 2` тогда; v1.7.3..NN всё это время будут писать без `version`.

**Detection**: `decoded['storage'] is Map<String, dynamic>`. Если нет → `FormatException('Unsupported backup format. Re-export from a recent app version.')`.

---

## Реализация

### `SettingsStorage` — 2 новых метода

`exportRaw()` ([settings_storage.dart:670](../../../app/lib/services/settings_storage.dart:670)) — alias на `dumpCache()`, возвращает deep-clone всего `_cache` через JSON round-trip. Использует тот же механизм что и `/state/storage` Debug API endpoint.

`replaceRaw(Map snapshot, {bool merge = false})` ([settings_storage.dart:676](../../../app/lib/services/settings_storage.dart:676)):
- `merge=false` (default): `_cache = clean; _save()` — overwrite целиком.
- `merge=true`: top-level merge. `vars` блок ресурсивно merge'ится (subkey-level upsert: новый `log_level` → overwrite; отсутствующий `auto_update_subs` → keep). Остальные top-level keys overwrite-as-whole (т.е. для `custom_rules` это full replace массива, что соответствует семантике replace).

### `BackupService` — переписан

`BackupCategory` enum получил **5-й вариант**: `vpnSettings` (+ существующие `serverLists`, `routing`, `appSettings`, `debugConfig`).

`buildExport`:
1. `SettingsStorage.exportRaw()` → raw map
2. `filterStorageForExport(raw, include: ...)` — UI-уровень фильтрации:
   - `server_lists` → если в include `serverLists`
   - `vars.*` subkeys → split по `_varDebugKeys = {debug_enabled, debug_token, debug_port}`: debug-keys → `debugConfig` category; rest → `appSettings`
   - top-level `custom_rules`, `route_final`, `rule_outbounds`, `enabled_rules`, `enabled_groups`, `tun_apps`, `excluded_nodes`, `dns_options` → `routing` category
   - top-level `ping_options`, `last_global_update`, `presets_migrated` → `appSettings`
   - **Unknown / future keys → `appSettings` (graceful default)** — если завтра добавится `data['foo_options']`, оно автоматом попадёт в App settings без правок этого filter'а
3. Если `include.contains(vpnSettings)` → `_readVpnSettings()` через `BoxVpnClient.{getAutoStart, getKeepOnExit, getBackgroundMode, getCoreLogsEnabled, getAllowBypass}`
4. Сериализовать в pretty-printed JSON

`parseImport`:
1. Validate `app == "lxbox"`, `kind == "backup"`
2. `decoded['storage'] is Map<String, dynamic>` → required (legacy reject)
3. Optional `decoded['vpn_settings']`
4. Return `BackupContents { createdAt, sourceAppVersion, storage, vpnSettings }`

`applyImport`:
1. Если есть `storage` → `_filterStorageForImport(raw, include)` (та же логика что filterStorageForExport — позволяет юзеру снять галочки в preview)
2. Для `serverLists` в `merge=true` — append-by-id вручную (через `SettingsStorage.getServerLists()` + `saveServerLists()`)
3. `SettingsStorage.replaceRaw(filtered, merge: merge)` — основной apply
4. Если есть `vpnSettings` в include → `_applyVpnSettings()` через `BoxVpnClient` setters, поштучно с try/catch

### Debug API `/backup/*`

[debug/handlers/backup.dart](../../../app/lib/services/debug/handlers/backup.dart) переписан под тот же wire-format:
- `GET /backup/export?include=storage,vpn_settings` (default = обе)
- `POST /backup/import?merge=&rebuild=` body `{storage?, vpn_settings?}`

Symmetric с UI. Файл export'нутый из UI можно скормить в `POST /backup/import` через curl, и наоборот.

### UI — BackupScreen

[backup_screen.dart](../../../app/lib/screens/backup_screen.dart): добавлен 5-й checkbox **"VPN system toggles"** (default ON). Preview-dialog (`_showImportPreview`) показывает новую категорию если она в файле. Counts:
- `vpnSettings: vpnSettings?.length ?? 0` — фиксированно 5 если блок есть, 0 иначе

`BackupContents` упрощён:
- Было: `serverLists: List<ServerList>?`, `routingVars: Map?`, `appVars: Map?`, `debugVars: Map?`
- Стало: `storage: Map?`, `vpnSettings: Map?`. Counts/`availableCategories`/`splitServerLists` derive'ятся от `storage` map при вызове.

---

## Тесты

[backup_service_test.dart](../../../app/test/services/backup_service_test.dart) — 13 cases:

1. `exportRaw deep-clone` — мутация returned map не аффектит storage
2. `replaceRaw(merge=false)` overwrites everything
3. `replaceRaw(merge=true)` preserves untouched keys
4. `buildExport full` — все категории → storage + metadata, no vpn_settings без toggle
5. `buildExport без debugConfig` — debug-keys stripped from vars
6. `buildExport только debugConfig` — keeps только debug-keys
7. `buildExport только routing` — top-level routing keys, без vars и server_lists
8. `parseImport rejects non-JSON`
9. `parseImport rejects file без app/kind markers`
10. `parseImport rejects legacy (no storage key)` — message contains "Unsupported"
11. `parseImport minimal valid backup`
12. **`round-trip: export → reset → import → bytewise equal`** — главный тест: после wipe + restore все ключи (`custom_rules`, `tun_apps`, `route_final`, `enabled_groups`, `dns_options`, `vars.debug_token`, `vars.wifi_history`, `server_lists`) идентичны original
13. `partial restore: routing-only` — pre-existing vars сохраняются + custom_rules добавляются

---

## Risks / edge cases

| Риск | Митигация |
|---|---|
| **Юзер пытается restore старый backup (`version: 1`)** | Reject с user-friendly message. Имена коротких backup'ов от 10 мая бэкапить нельзя — придётся пере-export'нуть после апдейта. |
| **`vpn_settings` блок не в backup'е** (юзер снял категорию) | Restore просто пропускает — native side остаётся как есть. |
| **`storage.vars.debug_token` экспортится при `debugConfig=ON`** | Default OFF; UI красный warning + опт-ин flag (без изменений из §040 V1) |
| **Restore в `merge=true` смешивает vars с разных версий app** | OK — vars upsert, отсутствующие в файле сохраняются. Сломать может только если ключ был renamed (тогда old name остаётся в storage пока юзер вручную не уберёт). |
| **`replaceRaw(empty {})`** | Полный wipe всех данных. Полезно для тестов; в UI defensive — нельзя послать пустой include set (`Nothing to export` snackbar). |
| **`presets_migrated` flag вместе с restored data** | Если файл содержит — restore оставляет; если нет — Routing screen прогонит migration на следующем открытии. Self-healing. |

---

## Что осталось open

- **Migration tool для старых backup'ов** (типа того что у юзера от 10 мая с inline "Ru Apps"). Standalone скрипт: распарсить `config.route.rule_set[].rules[].package_name` → `CustomRule.inline` → инжект в storage. Не сделан — юзер может попросить отдельно.
- **Manual `vpn_settings` schema validation** в parseImport — currently просто принимает `Map<String, dynamic>` и каждое поле опционально игнорирует если не bool/string. Достаточно для V1; если будет проблема — добавим explicit validator.

---

## Файлы изменены

| Файл | Что |
|---|---|
| [app/lib/services/settings_storage.dart](../../../app/lib/services/settings_storage.dart) | +`exportRaw()`, +`replaceRaw(map, merge:)` |
| [app/lib/services/backup_service.dart](../../../app/lib/services/backup_service.dart) | Переписан под single-format; удалены `BackupVersionException`, `kBackupSchemaVersion`, `_routingKeys`, `_debugKeys`, vars-сегментирование; +`BackupCategory.vpnSettings` |
| [app/lib/services/debug/handlers/backup.dart](../../../app/lib/services/debug/handlers/backup.dart) | Sync wire-format с BackupService |
| [app/lib/screens/backup_screen.dart](../../../app/lib/screens/backup_screen.dart) | +5-й checkbox "VPN system toggles"; preview категории |
| [app/test/services/backup_service_test.dart](../../../app/test/services/backup_service_test.dart) | NEW — 13 cases including round-trip |
| [docs/spec/features/040 backup restore ui/spec.md](../features/040%20backup%20restore%20ui/spec.md) | Update note наверху, статус Implemented |
| [docs/api/debug-api-reference.md](../../api/debug-api-reference.md) | `/backup/*` секция переписана |
| [CHANGELOG.md](../../../CHANGELOG.md) | Unreleased entry |
