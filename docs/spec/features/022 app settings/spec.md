# 022 — App Settings

| Поле | Значение |
|------|----------|
| Статус | Реализовано (v1.4.0) |

## Контекст

Настройки приложения, не связанные с конфигом sing-box: тема, стартап-поведение, фидбек юзеру, управление background'ом.

## Настройки

### Appearance

| Значение | Поведение |
|----------|-----------|
| System | Следует за системными настройками (default) |
| Light | Всегда светлая тема |
| Dark | Всегда тёмная тема |

Реализация: `ThemeMode` в `MaterialApp`, значение в `SharedPreferences` через `themeNotifier`.

### Startup

- **Auto-start on boot** — VPN стартует при загрузке устройства. Реализация: `BootReceiver` (BroadcastReceiver) + `RECEIVE_BOOT_COMPLETED` permission.
- **Keep VPN on exit** — VPN не гасится при swipe'е приложения из recents. Реализация: `onTaskRemoved` в `BoxVpnService` проверяет флаг.
- **Auto-rebuild config** — при любом изменении настроек (routing, подписки, vars) автоматом триггерится `generateConfig` + `saveParsedConfig`. Дефолт ON. Ключ `auto_rebuild`.

### Background (v1.4.0)

- **Battery optimization** tile:
  - Показывает текущий статус (`isIgnoringBatteryOptimizations` через PowerManager).
  - Зелёная иконка `battery_full` если whitelisted, красная `battery_alert` если restricted.
  - Tap открывает системную страницу battery-optimization (Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS). Fallback на direct-prompt `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` если primary не открылся.
  - AppLifecycle resumed → re-check статуса (юзер вернулся из settings, обновляем UI).
- **App info (OEM power settings)** tile:
  - Показывает инструкционный диалог ("Find these toggles in the next screen — Autostart / Background activity / Battery / Battery saver exceptions").
  - После Cancel/Open: Open запускает `Settings.ACTION_APPLICATION_DETAILS_SETTINGS` с package URI — system app info screen, где у OEM (Xiaomi/MIUI, Samsung, Oppo/ColorOS, Huawei) живут их тоглы.

### Feedback

- **Auto-ping after connect** (v1.4.0) — через 5 секунд после перехода в connected, `HomeController` триггерит `pingAllNodes()` для активной группы. Одноразово per connect. Дефолт ON. Ключ `auto_ping_on_start`. При disconnect — pending-timer cancel'ится.
- **Haptic feedback** (spec 029) — вибрация на connect/disconnect/error/heartbeat-fail. Уважает системный "Touch feedback". Дефолт ON. Ключ `haptic_enabled`.

## UI

Экран `AppSettingsScreen`, доступ из drawer:

```
┌──────────────────────────────────────────┐
│  ← App Settings                          │
├──────────────────────────────────────────┤
│  Appearance                              │
│   ○ System    ○ Light    ● Dark          │
├──────────────────────────────────────────┤
│  Startup                                 │
│   Auto-start on boot             [☐]    │
│   Keep VPN on exit               [☐]    │
│   Auto-rebuild config            [☑]    │
├──────────────────────────────────────────┤
│  Background                              │
│   🔋 Battery optimization          >     │
│      "Whitelisted — VPN can run..."      │
│   ⚙ App info (OEM power settings)  >     │
│      "OEM-specific toggles..."           │
├──────────────────────────────────────────┤
│  Feedback                                │
│   Auto-ping after connect        [☑]    │
│   Haptic feedback                [☑]    │
└──────────────────────────────────────────┘
```

## Хранение

`SharedPreferences` (через `SettingsStorage`):

| Ключ | Тип | Default | Где |
|------|-----|---------|-----|
| `theme_mode` | String | `system` | `lxbox_settings.json` |
| `auto_start_on_boot` | bool | false | native (BootReceiver) |
| `keep_vpn_on_exit` | bool | false | native |
| `auto_rebuild` | String | `"true"` | settings |
| `auto_ping_on_start` | String | `"true"` | settings |
| `haptic_enabled` | String | `"true"` | settings |

## Интеграция с HomeController

`onVpnConnected` (в `_statusSub` handler):
- haptic → `HapticService.I.onVpnConnected()`
- auto-updater → `_autoUpdater?.onVpnConnected()` (trigger #2, 2 мин delay)
- **auto-ping** → `_scheduleAutoPing()` — читает `auto_ping_on_start`, если true: `Timer(5s, () => pingAllNodes())`

`onVpnDisconnected` / `onVpnRevoked`:
- `_autoPingTimer?.cancel()` — одноразовый pending timer гасим чтобы ping не стрельнул после disconnect

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/app_settings_screen.dart` | UI; `WidgetsBindingObserver` для re-check battery status |
| `lib/vpn/box_vpn_client.dart` | `isIgnoringBatteryOptimizations`, `openBatteryOptimizationSettings`, `openAppDetailsSettings` |
| `android/.../VpnPlugin.kt` | Methods + `openSystemSettings` helper (activity-context fallback + logging) |
| `android/.../AndroidManifest.xml` | `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission |
| `lib/controllers/home_controller.dart` | `_autoPingTimer` + `_scheduleAutoPing` hook в `onVpnConnected` |
| `lib/main.dart` | ThemeMode из SharedPreferences |
| `android/.../BootReceiver.kt` | Проверка auto_start setting |
| `android/.../BoxVpnService.kt` | onTaskRemoved проверяет keep_vpn |

## Критерии приёмки

- [x] Тема переключается между System/Light/Dark
- [x] Auto-start on boot запускает VPN при загрузке
- [x] Keep VPN on exit контролирует поведение при свайпе
- [x] Auto-rebuild config триггерит regenerate при изменении routing/vars
- [x] Battery tile показывает корректный статус (green/red)
- [x] Battery tile tap открывает system settings (fallback если primary action не поддерживается OEM'ом)
- [x] App info tile показывает hint-dialog перед открытием
- [x] Auto-ping срабатывает через 5s после connected если enabled
- [x] Auto-ping отменяется при disconnect до 5s
- [x] Haptic feedback уважает system touch feedback + флаг
- [x] Все настройки сохраняются между запусками
