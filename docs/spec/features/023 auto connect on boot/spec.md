# 023 — Auto-connect on Boot

## Статус: Реализовано

## Контекст

Пользователь хочет чтобы VPN автоматически запускался при загрузке устройства, без ручного открытия приложения.

## Реализация

### Android BootReceiver
- `RECEIVE_BOOT_COMPLETED` permission в AndroidManifest.
- `BootReceiver` — BroadcastReceiver, запускает VPN сервис при `ACTION_BOOT_COMPLETED`.
- Настройка "Auto-start on boot" в App Settings (SharedPreferences).

### Stop on App Swipe
- Настройка "Keep VPN on exit" — если выключена, VPN останавливается при свайпе приложения из недавних.
- Реализовано через `onTaskRemoved` в VpnService.

## Файлы

| Файл | Изменения |
|------|-----------|
| `android/app/src/main/AndroidManifest.xml` | RECEIVE_BOOT_COMPLETED, BootReceiver |
| `android/app/src/main/.../BootReceiver.kt` | Запуск VPN при загрузке |
| `lib/screens/app_settings_screen.dart` | Toggle "Auto-start on boot" |

## Критерии приёмки

- [x] VPN запускается автоматически при загрузке устройства
- [x] Настройка включается/выключается в App Settings
- [x] "Keep VPN on exit" контролирует поведение при свайпе
