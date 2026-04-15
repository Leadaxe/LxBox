# 017 — Per-App Proxy (Split Tunneling)

## Контекст

Сейчас VPN туннелирует весь трафик всех приложений. Пользователь не может выбрать какие приложения идут через VPN, а какие напрямую. Это нужно для:
- Банковские приложения — часто блокируют VPN-трафик
- Игры — не нужен VPN, добавляет латентность
- Рабочие приложения — должны идти напрямую

## Что делаем

### Экран Per-App Proxy

Доступен из drawer или из Routing screen.

**AppBar:**
- Заголовок: "Per-App Proxy"
- Поиск (иконка → SearchBar)

**Режим (вверху):**
- SegmentedButton: `Off` / `Include` / `Exclude`
  - Off — все приложения через VPN (по умолчанию)
  - Include — только отмеченные через VPN
  - Exclude — все кроме отмеченных через VPN

**Список приложений:**
- Иконка + имя + package name
- Чекбокс справа
- Системные приложения скрыты по умолчанию, toggle "Show system apps"
- Сортировка: выбранные сверху, потом по алфавиту

### Хранение

В `boxvpn_settings.json`:
```json
"per_app_mode": "off",
"per_app_list": ["com.android.chrome", "org.telegram.messenger"]
```

### Нативная сторона

**Новые методы в VpnPlugin/MethodChannel:**
- `getInstalledApps` → List<Map> с `packageName`, `appName`, `isSystemApp`

**В BoxVpnService.openTun():**
- Читать mode и list из ConfigManager
- Применять builder.addAllowedApplication / addDisallowedApplication

### Хранение в ConfigManager

ConfigManager получает два новых поля:
- `perAppMode`: "off" | "include" | "exclude"
- `perAppList`: List<String> (package names)

Сохраняются через MethodChannel из Dart при нажатии Apply.

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/per_app_screen.dart` | Новый экран |
| `lib/screens/home_screen.dart` | Пункт в drawer |
| `lib/services/settings_storage.dart` | per_app_mode, per_app_list |
| `lib/vpn/box_vpn_client.dart` | getInstalledApps(), setPerAppProxy() |
| `VpnPlugin.kt` | getInstalledApps, setPerAppMode, setPerAppList |
| `ConfigManager.kt` | perAppMode, perAppList |
| `BoxVpnService.kt` | Применение в openTun() |
