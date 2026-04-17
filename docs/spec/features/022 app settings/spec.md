# 022 — App Settings

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

## Контекст

Настройки приложения, не связанные с конфигом sing-box: тема оформления, поведение при загрузке, поведение при свайпе.

## Настройки

### Theme (Тема оформления)

| Значение | Поведение |
|----------|-----------|
| System | Следует за системными настройками (по умолчанию) |
| Light | Всегда светлая тема |
| Dark | Всегда тёмная тема |

Реализация: `ThemeMode` в `MaterialApp`, значение хранится в `SharedPreferences`.

### Auto-start on boot

При включении VPN автоматически запускается при загрузке устройства.

Реализация: `BootReceiver` (BroadcastReceiver) + `RECEIVE_BOOT_COMPLETED` permission. Настройка хранится в `SharedPreferences`.

### Keep VPN on exit

При выключении VPN останавливается когда пользователь свайпает приложение из недавних.

Реализация: `onTaskRemoved` в VpnService проверяет эту настройку.

## UI

Экран `AppSettingsScreen`, доступен из drawer:

```
┌──────────────────────────────┐
│  ← App Settings              │
│                              │
│  Theme         [System    ▼] │
│                              │
│  Auto-start on boot     [☑] │
│  Keep VPN on exit       [☐] │
└──────────────────────────────┘
```

## Хранение

`SharedPreferences`:
- `theme_mode` — `system` | `light` | `dark`
- `auto_start_on_boot` — bool
- `keep_vpn_on_exit` — bool

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/app_settings_screen.dart` | UI экран |
| `lib/main.dart` | ThemeMode из SharedPreferences |
| `android/.../BootReceiver.kt` | Проверка auto_start setting |
| `android/.../BoxVpnService.kt` | onTaskRemoved проверяет keep_vpn |

## Критерии приёмки

- [x] Тема переключается между System/Light/Dark
- [x] Auto-start on boot запускает VPN при загрузке
- [x] Keep VPN on exit контролирует поведение при свайпе
- [x] Настройки сохраняются между запусками
