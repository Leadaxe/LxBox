# 012 — Native VPN Service

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

## Контекст

Приложение использовало сторонний pub.dev плагин `flutter_singbox_vpn`. Плагин непопулярен, хранит конфиг в SharedPreferences, содержит лишний код. Цель: перенести всю нативную Android логику напрямую в проект + добавить автоподключение при загрузке.

## Native VPN Service (удаление flutter_singbox_vpn)

### Убрано
- `flutter_singbox_vpn` из `pubspec.yaml`
- TileService, BootReceiver (заменён своим), ProxyService, AppChangeReceiver, per-app tunneling, traffic_events

### Нативный код в `android/app/`

Пакет: `com.leadaxe.boxvpn_app.vpn`

| Файл | Назначение |
|------|-----------|
| `VpnPlugin.kt` | Flutter MethodChannel + EventChannel мост |
| `BoxVpnService.kt` | Android VpnService + запуск libbox |
| `ConfigManager.kt` | Хранение конфига в файле (не SharedPreferences) |
| `ServiceNotification.kt` | Foreground notification |
| `VpnStatus.kt` | Enum статусов |

### Хранение конфига

Файл: `/data/data/com.leadaxe.boxvpn_app/files/singbox_config.json`

### Контракт Flutter <-> Android

**MethodChannel**: `"com.leadaxe.boxvpn/methods"`

| Метод | Вход | Выход |
|-------|------|-------|
| `saveConfig` | `config: String` | `bool` |
| `getConfig` | — | `String` |
| `startVPN` | — | `bool` |
| `stopVPN` | — | `bool` |
| `setNotificationTitle` | `title: String` | `bool` |

**EventChannel**: `"com.leadaxe.boxvpn/status_events"`

```json
{"status": "Started" | "Starting" | "Stopped" | "Stopping"}
```

## Auto-connect on Boot

**Status:** Реализовано

### Android BootReceiver
- `RECEIVE_BOOT_COMPLETED` permission в AndroidManifest.
- `BootReceiver` — BroadcastReceiver, запускает VPN сервис при `ACTION_BOOT_COMPLETED`.
- Настройка "Auto-start on boot" в App Settings (SharedPreferences).

### Stop on App Swipe
- Настройка "Keep VPN on exit" — если выключена, VPN останавливается при свайпе приложения.
- Реализовано через `onTaskRemoved` в VpnService.

## Файлы

| Файл | Изменения |
|------|-----------|
| `android/app/src/main/kotlin/.../vpn/VpnPlugin.kt` | Flutter plugin |
| `android/app/src/main/kotlin/.../vpn/BoxVpnService.kt` | VpnService |
| `android/app/src/main/kotlin/.../vpn/ConfigManager.kt` | Хранение конфига |
| `android/app/src/main/kotlin/.../vpn/ServiceNotification.kt` | Notification |
| `android/app/src/main/kotlin/.../BootReceiver.kt` | Запуск VPN при загрузке |
| `lib/vpn/box_vpn_client.dart` | Dart-обёртка |
| `android/app/src/main/AndroidManifest.xml` | RECEIVE_BOOT_COMPLETED, BootReceiver |

## Критерии приёмки

- [x] `flutter_singbox_vpn` удалён из `pubspec.yaml`.
- [x] VPN запускается и останавливается через нативный `BoxVpnService`.
- [x] Конфиг сохраняется в `files/singbox_config.json`.
- [x] Статусы корректно доходят до Dart через EventChannel.
- [x] Notification показывается при активном VPN.
- [x] VPN запускается автоматически при загрузке устройства.
- [x] "Keep VPN on exit" контролирует поведение при свайпе.
