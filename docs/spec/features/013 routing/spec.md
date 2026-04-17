# 013 — Routing

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

## Контекст

Routing охватывает: выбор outbound для каждого правила маршрутизации, отдельный экран Routing, per-app proxy правила.

## 1. Rule Outbound Selection & Route Final

### Выбор outbound для каждого правила

В настройках рядом с чекбоксом каждого правила — дропдаун с выбором outbound.

**Доступные варианты** (динамически):
- `direct` → `direct-out`
- `proxy` → `proxy-out`
- `auto` → `auto-proxy-out`
- `vpn-1` → `vpn-1` (только если группа включена)
- `vpn-2` → `vpn-2` (только если группа включена)

**Правила с `action`** (Block Ads → `action: reject`) — дропдаун не показывается.

### Настройка route.final

Строка **"Default traffic"** с дропдауном. Определяет `route.final` в конфиге. Default: `proxy-out`.

### Хранение

```json
"rule_outbounds": {
  "Russian domains direct": "direct-out",
  "BitTorrent direct": "vpn-1"
},
"route_final": "proxy-out"
```

## 2. Routing Screen

Отдельный экран, доступный из drawer.

### Секция "Proxy Groups"

Список групп из `template.presetGroups`. Каждая группа — SwitchListTile:
- Title: `group.label` (Auto Proxy, Proxy, VPN 1, VPN 2)
- Subtitle: тип (`urltest` / `selector`)
- Switch: включена / выключена

### Секция "Routing Rules"

Каждое правило — строка:
```
[Switch] Rule label          [DropDown outbound]
         Rule description
```

### Строка "Default traffic (route.final)"

```
Default traffic              [DropDown outbound]
Fallback for unmatched traffic
```

## 3. Per-App Proxy (App Routing Rules)

### Концепция: App Rule

**App Rule** — именованный список приложений с назначенным outbound.

```json
{
  "name": "Banks",
  "packages": ["ru.tinkoff.investing", "ru.sberbankmobile"],
  "outbound": "direct-out"
}
```

Генерирует sing-box routing rule с `package_name` + `outbound`.

### UI в Routing Screen

Секция **"App Rules"** после Routing Rules, перед Route Final.

Каждая строка:
```
[Icon] Rule name          N apps    [dropdown outbound]
```

- Тап → экран выбора приложений
- Кнопка **"+ Add App Rule"**

### AppPickerScreen

- Чекбокс + имя + package name
- Поиск
- Выбранные сверху
- Системные скрыты по умолчанию
- Popup menu: Select all, Deselect all, Invert, Show/hide system apps

### Генерация конфига

В `ConfigBuilder` после selectable rules, перед route.final:
- Для каждого app_rule — routing rule с `package_name` + `outbound`

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/routing_screen.dart` | Proxy Groups + Rules + outbound dropdowns + route.final + App Rules |
| `lib/screens/app_picker_screen.dart` | Выбор приложений для правила |
| `lib/screens/settings_screen.dart` | Убрать Proxy Groups и Routing Rules, оставить только vars |
| `lib/services/settings_storage.dart` | getRuleOutbounds, saveRuleOutbounds, getRouteFinal, saveRouteFinal, getAppRules, saveAppRules |
| `lib/services/config_builder.dart` | Применение user outbound, route.final, package_name rules |

## Критерии приёмки

- [x] Routing — отдельный экран из навигации.
- [x] Proxy Groups и Routing Rules убраны из Settings.
- [x] Каждое outbound-правило имеет дропдаун выбора outbound.
- [x] vpn-1/vpn-2 появляются в дропдауне только если группы включены.
- [x] Строка "Default traffic" управляет `route.final`.
- [x] App Rules: создание с именем и списком приложений.
- [x] Для каждого App Rule можно выбрать outbound.
- [x] Сгенерированный конфиг содержит routing rules с `package_name`.
