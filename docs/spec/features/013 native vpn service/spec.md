# 013 — Native VPN Service (удаление flutter_singbox_vpn)

## Контекст

Приложение использует сторонний pub.dev плагин `flutter_singbox_vpn` (v1.1.3, 0 звёзд, TecClub) для интеграции с sing-box ядром (libbox). Плагин:

- Непопулярен и не поддерживается сообществом — высокий риск заброшенности.
- Добавляет внешнюю зависимость на код, который полностью умещается в `android/` папке проекта.
- Хранит конфиг sing-box в SharedPreferences (XML), что семантически неверно для больших JSON-строк.
- Содержит ненужный нам код: TileService, BootReceiver, ProxyService, per-app tunneling, getInstalledApps.

Цель: перенести всю нативную Android логику напрямую в проект, убрать зависимость от плагина, улучшить качество кода.

## Что делаем

### Убираем
- `flutter_singbox_vpn` из `pubspec.yaml`
- Всё что пришло из плагина и нам не нужно:
  - `TileService` (Quick Settings tile)
  - `BootReceiver` (авто-старт при загрузке)
  - `ProxyService` (HTTP прокси режим)
  - `AppChangeReceiver` (реакция на установку приложений)
  - per-app tunneling (setPerAppProxyMode / setPerAppProxyList / getInstalledApps)
  - `traffic_events` EventChannel (статистика не используется в UI)

### Пишем нативный код в `android/app/`

Новый пакет: `com.leadaxe.boxvpn_app.vpn`

| Файл | Назначение |
|------|-----------|
| `VpnPlugin.kt` | Flutter MethodChannel + EventChannel мост |
| `BoxVpnService.kt` | Android VpnService + запуск libbox |
| `ConfigManager.kt` | Хранение конфига в файле (не SharedPreferences) |
| `ServiceNotification.kt` | Foreground notification |
| `VpnStatus.kt` | Enum статусов |

### Меняем хранение конфига

Вместо SharedPreferences — обычный файл:
```
/data/data/com.leadaxe.boxvpn_app/files/singbox_config.json
```

Это соответствует тому, как конфиг уже хранится в настройках приложения (`app_flutter/boxvpn_settings.json`).

### Контракт Flutter ↔ Android (сохраняем совместимость с Dart-стороной)

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

## Архитектура нативного кода

```
VpnPlugin.kt
  ├── MethodChannel("com.leadaxe.boxvpn/methods")
  │     saveConfig / getConfig / startVPN / stopVPN / setNotificationTitle
  ├── EventChannel("com.leadaxe.boxvpn/status_events")
  │     Broadcast receiver → StatusSink
  └── onActivityResult() → продолжение startVPN после VPN permission dialog

BoxVpnService.kt  (extends VpnService)
  ├── onStartCommand(ACTION_START)
  │     notification.show() → Libbox.newService() → service.start() → openTun()
  ├── onStartCommand(ACTION_STOP)
  │     service.close() → stopSelf()
  ├── openTun(TunOptions): Int
  │     Builder: MTU, адреса, маршруты → establish() → fd
  └── Broadcasts: STATUS_CHANGED (Starting/Started/Stopping/Stopped)

ConfigManager.kt
  ├── save(json: String)   → Files/singbox_config.json
  ├── load(): String       → читает файл, возвращает "{}" если нет
  └── notificationTitle: String  (in-memory, сбрасывается при перезапуске)

ServiceNotification.kt
  ├── Channel: "boxvpn_vpn_channel"
  └── show(title: String)
```

## Изменения в Dart-стороне

`home_controller.dart` — заменить импорт и обращения к плагину на `MethodChannel` напрямую или через тонкую обёртку `BoxVpnClient`:

```dart
// Было:
import 'package:flutter_singbox_vpn/flutter_singbox.dart';
final FlutterSingbox _singbox = FlutterSingbox();

// Станет:
import 'vpn/box_vpn_client.dart';
final BoxVpnClient _vpn = BoxVpnClient();
```

`BoxVpnClient` — тонкая Dart-обёртка над MethodChannel/EventChannel с идентичным API.

## Файлы

### Новые

| Файл | Что |
|------|-----|
| `android/app/src/main/kotlin/com/leadaxe/boxvpn_app/vpn/VpnPlugin.kt` | Flutter plugin |
| `android/app/src/main/kotlin/com/leadaxe/boxvpn_app/vpn/BoxVpnService.kt` | VpnService |
| `android/app/src/main/kotlin/com/leadaxe/boxvpn_app/vpn/ConfigManager.kt` | Хранение конфига |
| `android/app/src/main/kotlin/com/leadaxe/boxvpn_app/vpn/ServiceNotification.kt` | Notification |
| `android/app/src/main/kotlin/com/leadaxe/boxvpn_app/vpn/VpnStatus.kt` | Enum |
| `lib/vpn/box_vpn_client.dart` | Dart-обёртка |

### Изменённые

| Файл | Что меняется |
|------|-------------|
| `android/app/src/main/kotlin/com/leadaxe/boxvpn_app/MainActivity.kt` | Регистрация VpnPlugin |
| `android/app/src/main/AndroidManifest.xml` | Permissions + VpnService + убираем лишние receivers |
| `android/app/build.gradle` | Добавить libbox зависимость, убрать flutter_singbox_vpn |
| `pubspec.yaml` | Убрать flutter_singbox_vpn |
| `lib/controllers/home_controller.dart` | Использовать BoxVpnClient |

## Критерии приёмки

- [ ] `flutter_singbox_vpn` удалён из `pubspec.yaml` и не используется.
- [ ] VPN запускается и останавливается через нативный `BoxVpnService`.
- [ ] Конфиг сохраняется в `files/singbox_config.json`, не в SharedPreferences.
- [ ] Статусы (Starting / Started / Stopping / Stopped) корректно доходят до Dart через EventChannel.
- [ ] Notification показывается при активном VPN, убирается при остановке.
- [ ] Приложение собирается без ошибок (`flutter build apk`).
- [ ] Все существующие фичи работают: генерация конфига, Clash API, ping нод.
