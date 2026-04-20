# 013 — Routing

| Поле | Значение |
|------|----------|
| Статус | Исторический (superseded by [030](../030%20custom%20routing%20rules/spec.md) в v1.4.0) |

> **v1.4.0:** модель роутинга полностью пересобрана, см. [`030 custom routing rules`](../030%20custom%20routing%20rules/spec.md). `AppRule`, `SelectableRule` toggle-механизм и отдельные типы `CustomRule` объединены в единый `CustomRule` с параллельными match-полями. Ниже — исторический snapshot до v1.4.0.

## Контекст

Routing охватывает: выбор outbound для каждого правила маршрутизации, отдельный экран Routing, per-app proxy правила.

## 1. Rule Outbound Selection & Route Final

### Выбор outbound для каждого правила

В настройках рядом с чекбоксом каждого правила — дропдаун с выбором outbound.

**Доступные варианты** (динамически):
- `direct` → `direct-out`
- `auto` → `auto-proxy-out` (если галка Include Auto включена)
- `vpn-1` → `vpn-1` (всегда — базовая группа, галку выключить нельзя)
- `vpn-2` → `vpn-2` (если группа включена)
- `vpn-3` → `vpn-3` (если группа включена)

**Правила с `action`** (Block Ads → `action: reject`) — дропдаун не показывается.

### Настройка route.final

Строка **"Default traffic"** с дропдауном. Определяет `route.final` в конфиге. Default: `vpn-1`.

### Хранение

```json
"rule_outbounds": {
  "Russian domains direct": "direct-out",
  "BitTorrent direct": "vpn-1"
},
"route_final": "vpn-1"
```

## 2. Routing Screen

Отдельный экран, доступный из drawer.

### Секция "Proxy Groups"

Список групп из `template.presetGroups`. Каждая группа — SwitchListTile:
- Title: `group.label` (Include Auto, VPN ①, VPN ②, VPN ③)
- Subtitle: тип (`urltest` / `selector`)
- Switch: включена / выключена

**VPN ① — всегда включена (isRequired)**, свитч задизейблен. Это базовая группа, которая обязательно генерируется, чтобы у `route.final` был валидный target.

**Include Auto** — особая галка: управляет не отдельной группой, а **включением `auto-proxy-out` как urltest-outbound'а и ссылкой на него в `add_outbounds` групп `vpn-*`**. Если off — секция `auto-proxy-out` не генерируется вовсе, vpn-группы её не видят.

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
- [x] vpn-1 всегда доступен (галка заблокирована).
- [x] vpn-2/vpn-3 появляются в дропдауне только если группы включены.
- [x] Include Auto контролирует генерацию `auto-proxy-out` и его добавление в `vpn-*`.
- [x] Строка "Default traffic" управляет `route.final`.
- [x] App Rules: создание с именем и списком приложений.
- [x] Для каждого App Rule можно выбрать outbound.
- [x] Сгенерированный конфиг содержит routing rules с `package_name`.
