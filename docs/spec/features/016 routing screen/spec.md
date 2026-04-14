# 016 — Routing Screen

## Контекст

Экран Settings сейчас перегружен: в одной прокрутке живут Proxy Groups, Routing Rules и технические переменные (log level, Clash API, DNS и т.д.). Routing-специфичная логика (группы, правила, outbound для каждого правила, route.final) семантически не относится к "настройкам" — это отдельная сущность.

Выносим всё про роутинг в отдельный экран **Routing**, Settings остаётся только с техническими vars.

## Что делаем

### Новый экран: RoutingScreen

Навигация: отдельная вкладка или пункт в drawer — на одном уровне с Settings, Subscriptions, Servers.

**Структура экрана:**

---

#### Секция "Proxy Groups"

Список групп из `template.presetGroups`. Каждая группа — SwitchListTile:
- Title: `group.label` (Auto Proxy, Proxy, VPN ①, VPN ②)
- Subtitle: тип (`urltest` / `selector`)
- Switch: включена / выключена

---

#### Секция "Routing Rules"

Список правил из `template.selectableRules`. Каждое правило — строка с двумя элементами:

```
[Switch] Rule label          [DropDown outbound]
         Rule description
```

- Switch: правило включено / выключено
- DropDown (только если у правила есть `outbound` в шаблоне, т.е. не action-based):
  - Варианты: direct, proxy, auto, + vpn-1 и vpn-2 если их группы включены
  - Disabled если Switch выключен
  - Сохраняется в `SettingsStorage.saveRuleOutbounds()`

Правила без outbound (Block Ads → `action: reject`) — только Switch, без дропдауна.

---

#### Строка "Default traffic (route.final)"

В конце секции правил — отдельная строка:
```
Default traffic              [DropDown outbound]
Fallback for unmatched traffic
```

Те же варианты outbound что и для правил. Сохраняется в `SettingsStorage.saveRouteFinal()`.

---

#### Кнопка Apply

В AppBar (как сейчас в Settings). При нажатии — сохраняет все изменения и перегенерирует конфиг.

### Settings остаётся с

- Editable vars: Log level, Clash API, Clash secret, Resolve strategy, Auto-detect interface
- Кнопка Apply

Секции Proxy Groups и Routing Rules — полностью убираются из Settings.

### Навигация

Добавляем Routing как новый пункт навигации в `home_screen.dart` рядом с существующими вкладками/пунктами.

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/routing_screen.dart` | Новый экран (Proxy Groups + Rules + outbound dropdowns + route.final) |
| `lib/screens/settings_screen.dart` | Убрать Proxy Groups и Routing Rules, оставить только vars |
| `lib/screens/home_screen.dart` | Добавить навигацию к RoutingScreen |
| `lib/services/settings_storage.dart` | `getRuleOutbounds/saveRuleOutbounds`, `getRouteFinal/saveRouteFinal` (из спеки 015) |
| `lib/services/config_builder.dart` | Применение user outbound и route.final (из спеки 015) |

## Критерии приёмки

- [ ] Routing — отдельный экран, доступный из навигации.
- [ ] Proxy Groups и Routing Rules убраны из Settings.
- [ ] Каждое outbound-правило имеет дропдаун выбора outbound (direct/proxy/auto/vpn-1/vpn-2).
- [ ] vpn-1 и vpn-2 появляются в дропдауне только если их группы включены.
- [ ] Дропдаун отключён если Switch правила выключен.
- [ ] Строка "Default traffic" управляет `route.final`.
- [ ] Apply сохраняет всё и перегенерирует конфиг.
- [ ] Settings содержит только технические vars.
