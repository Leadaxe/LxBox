# §189 — native_prefs: зеркало Android-prefs в lxbox_settings.json

**Тип:** storage-архитектура (single source of truth)
**Статус:** 🔧 Спроектировано, реализация
**Приоритет:** Medium
**Связано:** §188 (TUN-тумблеры), §052/§049 F15/§124 (сами prefs), backup_service,
STORAGE.md, [ARCHITECTURE.md → Хранилище]

## Боль (юзер)

Шесть настроек живут ТОЛЬКО в native SharedPreferences (`boxvpn_boot.*`), вне
`lxbox_settings.json`. Непрозрачно: бэкап/импорт/UI читают их method-channel'ом
напрямую из native, а не из единого JSON. Юзер: «всему основа JSON — с него бэкап,
в него импорт; мне так проще и понятнее».

## Модель (согласовано): JSON = диск, native = оперативка

- **`lxbox_settings.json` — источник истины** (диск). Бэкап/импорт/экспорт/UI —
  отсюда. Прозрачно, всё в одном файле.
- **native SharedPreferences — рабочая копия** (оперативка) для Dart-less
  моментов: BOOT_COMPLETED (Flutter не запущен), swipe `onTaskRemoved` (движок
  мёртв), `openTun`/establish (native-поток). native читает СВОЮ копию синхронно.
- **Поток записи (write-through):** любой `setX` пишет в JSON (первично) → зеркалит
  в native. **native НИКОГДА не пишет JSON.**
- **Старт (sync):** `JSON ⇒ native` если расходятся (диск перезаливает оперативку).
  Само чинится: если native ушёл в сторону (adb/Debug API мимо JSON) — на следующем
  старте JSON выправит. native отстаёт максимум до следующего старта Flutter
  (приемлемо — write-through кэш).

## Шесть ключей (все зеркалим)

| native key (`boxvpn_boot.*`) | JSON-поле | Dart-путь | В UI? |
|---|---|---|---|
| `auto_start_vpn` | `auto_start` | get/setAutoStart ✓ | ✓ |
| `keep_vpn_on_exit` | `keep_on_exit` | get/setKeepOnExit ✓ | ✓ (§188 Mode) |
| `background_mode` | `background_mode` | get/setBackgroundMode ✓ | ✓ |
| `core_logs_enabled` | `core_logs_enabled` | get/setCoreLogsEnabled ✓ | ✓ (Diagnostics) |
| `allow_bypass` | `allow_bypass` | get/setAllowBypass ✓ | ✓ (§188 Mode) |
| `auto_redirect` | `auto_redirect` | **ОТСУТСТВУЕТ — доделать** | нет (root-only, §124) |

`auto_redirect` (§124, root-only tproxy, default false) — единственный без
Dart-обёртки и без backup. Доделываем: method_name + Dart get/set + VpnPlugin
handler (native `BootReceiver.is/setAutoRedirect` уже есть). UI не добавляем (его
таска отдельная) — но в зеркало кладём для полноты.

## JSON-схема — секция `native_prefs`

Имя `native_prefs` (НЕ `native_vpn_settings` — там auto_start/core_logs не про VPN;
НЕ `AndroidSharedPreferences` — не протекаем Android-спецификой в имя). Роль:
JSON-зеркало native-preferences.

```json
"native_prefs": {
  "auto_start": false,
  "keep_on_exit": true,
  "background_mode": "never",
  "core_logs_enabled": false,
  "allow_bypass": false,
  "auto_redirect": false
}
```

Типы: bool ×5 + `background_mode` String (`never`/`auto`/`always` — wireValue).

## Механика

### Запись (write-through) — Dart первичен
Новый слой `NativePrefs` (Dart, в SettingsStorage или отдельный сервис):
- `NativePrefs.set<T>(key, value)`: пишет в `_cache['native_prefs'][key]` (JSON,
  flush) → затем `_vpn.setX(value)` (зеркало в native).
- UI и Debug API зовут ЭТОТ слой, НЕ `_vpn.setX` напрямую.
- §188-хэндлеры (vpn_mode_tab `_toggleKeepOnExit`/`_toggleAllowBypass`) и
  settings_screen (`_applyBackgroundMode`, auto_start, core_logs) → переводим на
  `NativePrefs.set`.

### Чтение — из JSON
- UI грузит из `native_prefs` секции (не method-channel). Быстрее (нет IPC), один
  источник.
- native в boot/swipe/establish читает СВОЮ копию (как сейчас) — не меняется.

### Старт (sync JSON ⇒ native)
В `main`/инициализации (после загрузки SettingsStorage, до UI):
`NativePrefs.syncToNative()` — для каждого ключа: если `json[key] != nativeGet()`
→ `nativeSet(json[key])`. Диск перезаливает оперативку.

### Bootstrap (первый старт после обновления)
Секции `native_prefs` ещё нет (существующие юзеры). ОДНОРАЗОВО: читаем native
(`getX` ×6) → пишем в JSON. Диск пуст → seed'им из оперативки. ЕДИНСТВЕННЫЙ случай
native⇒JSON. Условие: `_cache['native_prefs'] == null` → seed, иначе → нормальный
sync JSON⇒native.

### Backup
`_readVpnSettings` → читать из `native_prefs` JSON-секции (не `getX`).
`_applyVpnSettings` → писать через `NativePrefs.set` (JSON + native). Формат wire
бэкапа НЕ меняем (ключи те же: auto_start, keep_on_exit, ...) — обратная
совместимость старых бэкапов. + `auto_redirect` добавляется в backup-набор.

## Точки правки

- `app/lib/services/settings_storage/native_prefs.dart` (NEW, part) — слой
  `NativePrefs` (get из JSON / set write-through / syncToNative / bootstrap).
- `app/lib/vpn/box_vpn_client.dart` + `method_names.dart` — добавить
  `get/setAutoRedirect`.
- `app/android/.../VpnPlugin.kt` — handler `get/setAutoRedirect` (native уже есть).
- `app/lib/main.dart` (или app init) — вызвать `NativePrefs.bootstrapAndSync()`.
- `vpn_mode_tab.dart` (§188), `settings_screen.dart` — UI читает/пишет через
  `NativePrefs` вместо `_vpn.getX/setX` напрямую.
- `backup_service.dart` + `handlers/backup.dart` — read из JSON-секции, write
  через NativePrefs; +auto_redirect.
- `docs/STORAGE.md` — `native_prefs` секция в схеме lxbox_settings.json + пометка
  «зеркало boxvpn_boot.*».
- `docs/ARCHITECTURE.md` — раздел «Хранилище» (см. §190, отдельно).

## Границы / риски

- native остаётся авторитетным для boot/swipe/establish (читает свою копию) —
  sync JSON⇒native гарантирует свежесть к следующему старту, не мгновенно.
- НЕ менять wire-формат бэкапа (ключи) — старые бэкапы импортируются.
- `getCurrentSessionAllowBypass` (§069, runtime snapshot) — НЕ prefs, НЕ зеркалим
  (это applied-значение сессии, не настройка).
- Bootstrap идемпотентен: только при отсутствии секции.
- `auto_redirect` без UI — в зеркале есть, тогглить пока только Debug API/adb.
