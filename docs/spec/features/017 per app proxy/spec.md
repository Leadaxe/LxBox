# 017 — App Routing Rules (Per-App Outbound)

## Контекст

Пользователь хочет направлять трафик определённых приложений через конкретный outbound. Например:
- Банковские приложения → `direct-out` (VPN мешает)
- Рабочие приложения → `vpn-1`
- Торренты → уже есть через selectable rules, но не по приложению

Реализация через sing-box routing rules с `package_name` условием.

## Что делаем

### Концепция: App Rule

**App Rule** — именованный список приложений с назначенным outbound.

```json
{
  "name": "Banks",
  "packages": ["ru.tinkoff.investing", "ru.sberbankmobile"],
  "outbound": "direct-out"
}
```

Пользователь создаёт сколько угодно App Rules. Каждый генерирует одну sing-box routing rule:
```json
{
  "package_name": ["ru.tinkoff.investing", "ru.sberbankmobile"],
  "outbound": "direct-out"
}
```

### UI в Routing Screen

Новая секция **"App Rules"** после Routing Rules, перед Route Final.

#### Список App Rules

Каждая строка:
```
[Icon] Rule name          N apps    [dropdown outbound]
```

- Тап → экран выбора приложений для этого правила
- Long press / свайп → удалить

Кнопка **"+ Add App Rule"** внизу секции.

#### Экран выбора приложений (AppPickerScreen)

Открывается при тапе на App Rule или при создании нового.

**AppBar:**
- Заголовок: имя правила (редактируемое)
- Popup menu: Select all, Deselect all, Invert, Show/hide system apps, Import/Export clipboard

**Список:**
- Чекбокс + имя + package name
- Поиск
- Выбранные сверху
- Системные скрыты по умолчанию

**При выходе** — автосохранение.

### Хранение

В `boxvpn_settings.json`:
```json
"app_rules": [
  {
    "name": "Banks",
    "packages": ["ru.tinkoff.investing", "ru.sberbankmobile"],
    "outbound": "direct-out"
  },
  {
    "name": "Work",
    "packages": ["com.slack", "com.microsoft.teams"],
    "outbound": "vpn-1"
  }
]
```

### Генерация конфига

В `ConfigBuilder` после selectable rules, перед route.final:
- Для каждого app_rule генерируется routing rule с `package_name` + `outbound`
- Правила добавляются в конец `route.rules[]` (перед final)

### Нативная сторона

**VpnPlugin.getInstalledApps** — уже реализован, возвращает список пакетов.

**BoxVpnService.openTun** — убираем per-app include/exclude логику (вместо неё sing-box сам роутит по package_name через конфиг). Возвращаем стандартное поведение.

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/routing_screen.dart` | Секция App Rules + outbound dropdown |
| `lib/screens/app_picker_screen.dart` | **Новый** — выбор приложений для правила |
| `lib/services/settings_storage.dart` | getAppRules/saveAppRules |
| `lib/services/config_builder.dart` | Генерация package_name routing rules |
| `lib/vpn/box_vpn_client.dart` | getInstalledApps (уже есть) |

## Критерии приёмки

- [ ] Пользователь может создать App Rule с именем и списком приложений.
- [ ] Для каждого App Rule можно выбрать outbound (direct/proxy/auto/vpn-X).
- [ ] Сгенерированный конфиг содержит routing rules с `package_name`.
- [ ] Приложения из правила реально идут через выбранный outbound.
- [ ] Экран выбора приложений: поиск, select all, invert, show system.
- [ ] App Rules отображаются в секции Routing Screen.
