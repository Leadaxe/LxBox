# 017 — Custom Nodes & Node Settings

| Поле | Значение |
|------|----------|
| Статус | Спека |

## Контекст

Пользователь не может: добавить ноду вручную (свой сервер), отредактировать подписочную ноду, переименовать тег, настроить detour для прямого сервера.

## 1. Custom Nodes (Manual + Overrides)

### Хранение

В `boxvpn_settings.json`:

```json
"custom_nodes": [
  {
    "tag": "my-server",
    "type": "vless",
    "server": "1.2.3.4",
    "server_port": 443,
    "uuid": "abc-123",
    "tls": { "enabled": true }
  },
  {
    "tag": "My US Server",
    "override": "🇺🇸 US-Server-1",
    "server_port": 8443
  }
]
```

- `tag` — тег ноды
- `override` — если присутствует, тег подписочной ноды для патча (deep merge)

### Применение в ConfigBuilder

1. **Overrides**: deep merge поля поверх оригинального outbound
2. **Manual nodes**: добавить как отдельный outbound

### UI — Long press на ноде

- Ping
- Use this node
- Copy link (URI формат)
- **Edit** → JSON editor с outbound'ом
- **Reset** (только для overridden нод)

### Add node

- Вставить URI (vless://, vmess://) → парсится в outbound
- JSON editor с нуля

### Индикация

- Override → иконка карандаша
- Manual → иконка звёздочки

## 2. Node Settings (Detour & Tag)

### Визуальное различие в списке подписок

| Тип | Trailing |
|-----|----------|
| Подписка (N нод) | Chip с количеством `[12]` |
| Прямой сервер | Иконка сервера `Icons.dns` |

Тап на подписку → SubscriptionDetailScreen. Тап на прямой сервер → NodeSettingsScreen.

### NodeSettingsScreen

**Секция: Основное**

**Tag (название ноды)** — TextField с подписью.

**Секция: Routing**

**Detour (цепочка серверов)** — DropdownButton:
- "None (direct)" — без цепочки
- Все ноды из всех источников, кроме самой себя

```
┌─────────────────────────────────────────┐
│  Detour                                 │
│  ┌──────────────────────────────────┐   │
│  │ wg-parnas                      ▼ │   │
│  └──────────────────────────────────┘   │
│  Phone → wg-parnas → this server → Web  │
└─────────────────────────────────────────┘
```

**Секция: Info (read-only)**

| Поле | Пример |
|------|--------|
| Protocol | wireguard |
| Server | 212.232.78.237:51820 |
| URI | tap to reveal |

### Хранение overrides

```json
"node_overrides": {
  "original-tag": {
    "custom_tag": "my-vpn-germany",
    "detour": "wg-parnas"
  }
}
```

### ConfigBuilder

`_applyNodeOverrides`: tag rename + detour добавление.

### SubscriptionDetailScreen — контекстное меню нод

Long press на ноде в detail screen:
- Copy node info (`scheme://server:port#label`)
- Copy tag

### Autosave

Debounce 500ms, без кнопки Apply.

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/services/settings_storage.dart` | getCustomNodes, saveCustomNodes, getNodeOverrides, saveNodeOverride |
| `lib/services/config_builder.dart` | Overrides, manual nodes, _applyNodeOverrides |
| `lib/screens/node_edit_screen.dart` | JSON editor для ноды |
| `lib/screens/node_settings_screen.dart` | Tag, detour dropdown, info |
| `lib/screens/subscriptions_screen.dart` | Различие trailing, разный onTap |
| `lib/widgets/node_row.dart` | Индикация override/manual |

## Критерии приёмки

- [ ] Можно создать ноду вручную (URI или JSON).
- [ ] Можно отредактировать подписочную ноду (override, deep merge).
- [ ] Переименование тега работает.
- [ ] Copy link копирует URI ноды.
- [ ] Overridden ноды визуально отмечены.
- [ ] Подписки показывают Chip, прямые серверы — иконку.
- [ ] Тап на прямой сервер → NodeSettingsScreen.
- [ ] Можно изменить tag и выбрать detour.
- [ ] Нельзя выбрать саму себя как detour.
- [ ] Autosave с debounce 500ms.
- [ ] Overrides применяются в ConfigBuilder.
