# 040 — Backup & restore UI

| Поле | Значение |
|------|----------|
| Статус | Implemented (UI шипнут v1.6.0; format переписан в v1.7.3+ — см. **«Update v1.7.3 — single-format snapshot»** ниже) |
| Дата | 2026-05-01, обновление 2026-05-10 |
| Зависимости | [`031 debug api`](../031%20debug%20api/spec.md) (использует существующую модель `/backup/*` API) |
| Триггер | Пользователь хочет переносить настройки/подписки между устройствами без manual JSON-copy через Debug API. UI-flow с галочками — что включать в export/import. |

> **⚠ Update v1.7.3 — single-format snapshot**
>
> Изначальный wire-format (`vars` + `server_lists` на корне, `version: 1`) **не сохранял большую часть user data**: `custom_rules`, `tun_apps`, `enabled_groups`, `enabled_rules`, `route_final`, `rule_outbounds`, `dns_options` живут как **top-level ключи** `lxbox_settings.json`, а старый `BackupService.buildExport` вызывал `SettingsStorage.getAllVars()` который возвращал только `data['vars']`. Restore из таких backup'ов терял routing.
>
> Текущий формат (single, без `version`):
> ```json
> {
>   "app": "lxbox", "kind": "backup",
>   "created_at": "...", "source_app_version": "...",
>   "storage": { ...lxbox_settings.json целиком... },
>   "vpn_settings": { auto_start, keep_on_exit, background_mode,
>                     core_logs_enabled, allow_bypass }
> }
> ```
>
> - **`storage`** — deep-clone всего `lxbox_settings.json` через `SettingsStorage.exportRaw()`. Restore — `replaceRaw(map, merge: bool)`. Любой будущий top-level ключ попадает в backup автоматически — без правок allowlist'ов.
> - **`vpn_settings`** — отдельный native-side state (`boxvpn_boot` SharedPreferences, читается BootReceiver'ом at boot-time когда Flutter ещё не запущен, не перенесён в Flutter storage). 5 toggles через `BoxVpnClient` getters/setters.
> - **`version` поле убрано** — single format, файлы старого образца reject'ятся с `Unsupported backup format. Re-export from a recent app version.`
> - **5 категорий UI** (было 4): Server lists, Routing, App settings, **VPN system toggles** (новая), Debug API. Filter работает на уровне keys в `storage` map.
>
> Секции ниже описывают **изначальный** дизайн (UX flow, категории, рассуждения). Wire-format-секция (`Filter map`, `BackupContents` фрагмент) **устарели** — см. реализацию в [`backup_service.dart`](../../../app/lib/services/backup_service.dart).

## Цель

UI поверх существующих `/backup/export` + `/backup/import` Debug API endpoints с **гранулярным контролем что включать**. Пользователь видит, что у него внутри backup'а, и решает per-категория.

**Не в скопе:**
- **Encryption / password protection** — пользователь сам решает где хранить файл; для V1 plain-JSON без шифрования.
- **Cloud auto-backup** (Google Drive, iCloud) — отдельная большая задача.
- **Generated sing-box config export** — re-derivable из server_lists + routing rules; выкидываем из toggle list.
- **Per-server-list selection** (выбор конкретных подписок) — V1 all-or-nothing для категории "Server lists"; granularity на уровне 4 категорий, не каждой подписки.

---

## UX flow

### Где в UI

`Settings screen` → новая секция **"Backup & restore"** (между `Battery` и `Debug API`).

```
Settings
├── General (autostart, keep-on-exit, theme)
├── Notifications
├── Battery
├── Backup & restore                        ← новая секция
│     [📤 Export...] [📥 Import...]
└── Debug API
```

### Export flow

1. Tap **📤 Export...** → AlertDialog с checkbox-ами (см. ниже)
2. Кнопка **Export** → builds JSON → `share_plus` (юзер выбирает куда сохранить: файл / Telegram / Mail / etc.)
3. Filename: `lxbox-backup-v{version}-{YYYYMMDD-HHMM}.json`
   - Пример: `lxbox-backup-v1.6.0-20260501-1230.json`

### Import flow

1. Tap **📥 Import...** → `file_picker` → выбрать `*.json`
2. Parse + validate (`app: lxbox, kind: backup, version: 1`)
   - На invalid → error dialog "Not a valid LxBox backup"
   - На version mismatch → error dialog с подсказкой обновить app
3. **Preview dialog** с counts и теми же 4 checkboxes (default — отмечено всё, что есть в файле):
   ```
   Backup preview
   ──────────────
   Created: 2026-04-30 14:30
   App version: 1.6.0
   
   Includes:
   ☑ 4 server lists (3 subs, 1 custom)
   ☑ Routing — 5 rules, final: vpn-1
   ☑ 47 app settings
   ☐ Debug API config — present but unchecked
   
   Mode:
   ○ Replace all current data (destructive)
   ● Merge with existing (recommended)
   
   [Cancel]  [Import]
   ```
4. Apply → SnackBar "Imported: 4 server lists, routing (5 rules), 47 settings"

### Confirm-dialog для destructive operations

**Replace mode на Import** — показываем дополнительный confirm: «This will overwrite all your current data. Continue?» с явным красным action.

---

## Категории (4 галочки)

| Галочка | Default | Что включает | Wire-format keys |
|---|---|---|---|
| **Server lists** | ☑ ON | Все `server_lists` — и URL-подписки (`SubscriptionServers`), и собственные сервера (`UserServer`) объединено в один блок. Подписки и custom-servers концептуально похожи (источники нод), разделять их toggle'ом избыточно. | `server_lists: [...]` |
| **Routing** (groups + rules + final) | ☑ ON | **Вся routing-структура одним блоком**: outbound groups (`vpn-1`, `✨auto` — selectors/urltest), custom routing rules ([§030](../030%20custom%20routing%20rules/spec.md)) и `route.final` (default outbound). Эти три entity между собой связаны: rules ссылаются на groups by tag, `final` тоже = group tag. Разделять toggle'ом нет смысла — orphaned rules/final без своих groups = invalid конфиг. | `vars.custom_rules`, `vars.route_final`, plus groups derive from `server_lists` (см. ниже) |
| **App settings** | ☑ ON | Все остальные `vars` — общие preferences UI: theme, **language** (future), autostart, keep-on-exit, ping_url, ping_timeout, background_mode, auto_update_subs, auto_check_updates, и любые новые preferences которые появятся в будущем. Категория **намеренно catch-all** — добавляешь новый toggle в Settings → автоматом backup'ится без правок этого spec'а. | `vars.{rest}` |
| **Debug API config** | ☐ **OFF** | `debug_enabled`, `debug_token`, `debug_port`. Чувствительно: token даёт полный доступ к app'у через HTTP API. **Default OFF + warning text** в dialog. | `vars.{debug_*}` |

### Почему такое разделение

- **Server lists ↔ Routing** разделены: пользователь может захотеть поделиться **сетапом маршрутизации** (groups + rules + final) с другом, **без** выдачи своих провайдеров (server_lists с UUID/токенами). Или наоборот — отдать подписочный list, не отдавая своих кастомных правил роутинга.
- **App settings** отдельно — общие preferences UI, не критичны для восстановления routing'а.
- **Debug API config** изолирован — вынесен из общих `App settings` чтобы не leak'нуть случайно.

### Связь Server lists ↔ Routing — целевые сценарии

**Routing без Server lists — это feature, а не bug.** Главный use-case:

> «Я держу собственный отлаженный routing (блокировки рекламы, Россия→direct, странам-клиентам→VPN). Поделюсь конфигом с другом — пусть он использует мои rules + final, но **подписки свои**.»

Это работает **в большинстве случаев**, потому что:
- Стандартные groups (`vpn-1`, `✨auto`, `direct-out`) — **template-based**, есть у всех (заданы в `wizard_template.json`)
- `custom_rules` обычно ссылаются именно на эти стандартные tags
- `route.final = "vpn-1"` тоже стандартный

**Когда могут быть проблемы:**
- Если rules ссылаются на **subscription-specific group tags** (например `BL:🇷🇺Россия` из конкретного провайдера). На устройстве получателя этой подписки нет → orphaned reference.
- В таком случае rules с unknown tag'ами либо игнорируются sing-box'ом, либо вызывают config validation error.

**Поведение V1**: разрешаем импорт Routing без Server lists. **Не показываем алармирующий warning** — это валидный сценарий. Информационный hint в Import dialog: «Routing использует только стандартные groups (vpn-1, ✨auto, direct-out)? Можно импортить без Server lists. Custom group tags из конкретных подписок — проверьте что они есть на этом устройстве.»

**Симметрично работает обратное** — импорт Server lists без Routing: подписки заехали, но без custom_rules. Юзер использует default-routing (всё в `vpn-1`).

### Что НЕ переносится (намеренно)

| | Почему |
|---|---|
| `cache.db` (sing-box cache) | Восстанавливается за минуту работы; not portable между устройствами |
| `stderr.log` / `applog.txt` | Diagnostic-only; есть отдельный Share-dump (§038) |
| Local SRS rule_set blobs | Скачиваются из internet; регенерируются |
| История подключений / traffic stats | Privacy + ноль ценности при restore |
| Generated sing-box config (раньше был toggle) | Re-derivable из server_lists + rules; включать → bloat |

### "Groups" / "Channels" — где они в категориях

В app'е есть понятие "channels" / "groups" — outbound selectors типа `vpn-1`, urltest `✨auto` (видны на Home screen). Структурно они **не хранятся явно** в SettingsStorage — derive'ятся at config-build time:
- Из `server_lists` (каждый sub генерит свою группу с `tag_prefix`'ом)
- Из шаблона `wizard_template.json` (default-структура `vpn-1`, `✨auto`)

**Где они в наших toggles:**
- **Implicit в `Server lists` toggle**: групповая структура восстанавливается автоматически при rebuild config'а после import'а server_lists.
- **Logically принадлежат `Routing` toggle** (с точки зрения пользователя): `custom_rules` + `route.final` ссылаются на эти groups by tag, поэтому концептуально routing-блок «знает про groups».

Pure UX: пользователь видит **3 связанных категории** (Server lists ↔ Routing ↔ App settings) с естественным именованием; внутренние derivation-детали скрыты.

---

## Технические детали реализации

### Слой Dart-side (не через HTTP API)

UI **не использует** `/backup/export` HTTP endpoint — это для разработчика через `adb forward + curl`. Логика export/import дублируется на Dart-стороне в новом `BackupService`:

- **Direct calls**: `SettingsStorage.getAllVars()`, `SettingsStorage.getServerLists()`, `BoxVpnClient().getConfig()` (если включён generated config — но мы выкинули это из toggles).
- **Filtering** `vars` map в Dart по toggle: разрезаем на 3 группы (`routing` / `app` / `debug`) по списку известных ключей.
- **Wire-format совместим** с HTTP `/backup/*`: те же `app/kind/version`, те же `server_lists`, `vars` keys. Файл, экспортированный из UI, можно скормить и в `POST /backup/import` через curl, и наоборот.

### Filter map (vars → categories)

```dart
const _routingKeys = {'custom_rules', 'route_final'};
const _debugKeys = {'debug_enabled', 'debug_token', 'debug_port'};

Map<String, dynamic> filterVars(Map<String, dynamic> all, {
  required bool routing,
  required bool app,
  required bool debug,
}) {
  return {
    for (final e in all.entries)
      if ((_routingKeys.contains(e.key) && routing) ||
          (_debugKeys.contains(e.key) && debug) ||
          (!_routingKeys.contains(e.key) &&
           !_debugKeys.contains(e.key) &&
           app))
        e.key: e.value,
  };
}
```

### `lib/screens/backup_screen.dart`

`StatefulWidget` со state:
```dart
bool _includeServerLists = true;
bool _includeRouting = true;          // groups + rules + final
bool _includeAppSettings = true;
bool _includeDebugConfig = false;
```

Два больших Card'а: Export, Import. Внутри Export Card'а — список CheckboxListTile + кнопка `Export`.

### `lib/services/backup_service.dart`

```dart
enum BackupCategory { serverLists, routing, appSettings, debugConfig }

class BackupService {
  /// Build JSON для export'а согласно toggles.
  Future<String> buildExport({required Set<BackupCategory> include});

  /// Parse + validate import JSON. Throws на invalid.
  Future<BackupContents> parseImport(String json);

  /// Apply preview согласно toggles (юзер мог снять галочки).
  Future<BackupApplyResult> applyImport(
    BackupContents contents, {
    required bool merge,
    required Set<BackupCategory> include,
  });
}

class BackupContents {
  final DateTime? createdAt;
  final String? sourceAppVersion;
  final List<ServerList>? serverLists;       // category: serverLists
  final Map<String, dynamic>? routingVars;   // category: routing (custom_rules, route_final)
  final Map<String, dynamic>? appVars;       // category: appSettings (rest)
  final Map<String, dynamic>? debugVars;     // category: debugConfig (debug_*)
}
```

### Зависимости

- **`file_picker: ^Y.Z.W`** — добавить в `pubspec.yaml` для Import file pick
- **`share_plus: ^10.x`** — уже есть для Export sharing

### Versioning

Schema `version: 1`. Future versions могут break — для V1 reject unknown versions с user-facing error. Migration logic — отдельная задача когда появится v2.

---

## Test plan

### Smoke
1. Export со всеми галочками → файл создаётся, валидный JSON
2. Import того же файла на чистый app → 100% restore (server_lists count, vars count, custom_rules count)
3. Round-trip: export → wipe → import → state идентичен

### Selective
4. Export только `Server lists` (остальные галочки сняты) → импорт не трогает settings
5. Export только `App settings` → импорт не трогает server_lists
6. Export с `Debug API config` (явно opt-in) → файл содержит token/port

### Modes
7. **Replace mode**: текущие 5 server_lists, в файле 3 → после Import → 3 server_lists (старые пропали)
8. **Merge mode**: текущие 5, в файле 3 (2 совпадают по id) → после Import → 6 unique (5 + 1 новый)

### Edge cases
9. Invalid JSON → error toast, ничего не применилось
10. Backup от другого app (`app: not-lxbox`) → reject с message
11. Future version (`version: 99`) → reject с "please update LxBox"
12. Missing fields (только server_lists, нет vars) → import только то что есть, no crash
13. Confirm dialog на **Replace** мод — отказался → noop

### UX
14. SnackBar после успешного Import показывает counts
15. После Import в Replace mode — UI re-rendered с новыми server_lists без рестарта app

---

## Risks

| Риск | Митигация |
|---|---|
| **Replace mode уничтожает данные** | Confirm dialog с явным "destructive" red action; merge — default |
| **Subscription URLs leak** при шеринге backup'а | Warning text в Export dialog рядом с `Server lists` toggle: "Подписочные URL могут содержать ключи доступа к провайдеру" |
| **Debug token leak** | Default OFF + красный warning text "Includes a token that grants full HTTP access to your app instance" |
| **Импорт от старой/новой версии** | Schema `version` проверяется; mismatch → fail-soft с user-message |
| **Custom group tags** в импортнутых правилах не существуют (юзер импортит routing с сервера-специфичными tags вроде `BL:🇷🇺Россия` — а такой подписки на этом устройстве нет) | Не блокируем — главный use-case это «share routing with own subs», стандартные tags (`vpn-1`/`✨auto`/`direct-out`) у всех есть. Sing-box config validation на rebuild поймает unknown reference и покажет в "Errors" — юзер откроет Routing screen, удалит/поправит rule вручную |
| **Race с активным VPN** при Replace | Imp не трогает runtime state. Rebuild config + setStatus уведомит home — обновится при следующем connect |

---

## Rollback

Feature scoped в один screen + один service. Revert тривиален — удалить файлы + entry в App Settings.

## Зависимости от внешних артефактов

- `file_picker` package (pub.dev) — добавляется в pubspec
- Никаких native-API дополнений; pure Dart

## Обновления в других местах

- `app/pubspec.yaml`: `+ file_picker: ^X.Y.Z`
- `app/lib/screens/app_settings_screen.dart`: добавить ListTile "Backup & restore"
- `CLAUDE.md`: упомянуть spec 040 в списке features
- `CHANGELOG.md`: запись в Unreleased
