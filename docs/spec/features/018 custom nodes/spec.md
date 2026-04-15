# 018 — Custom Nodes (Manual + Overrides)

## Контекст

Пользователь не может:
- Добавить ноду вручную (свой сервер)
- Отредактировать подписочную ноду (поменять порт, сервер, TLS)
- Переименовать тег ноды

## Концепция

**custom_nodes** — массив пользовательских нод. Каждая нода — либо полностью ручная, либо патч (override) поверх подписочной.

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

**Поля:**
- `tag` — тег ноды в конфиге (для override — новое имя, или совпадает с оригиналом)
- `override` — если присутствует, это тег подписочной ноды для патча. Поля из custom_node мержатся поверх оригинального outbound (deep merge)
- Остальные поля — sing-box outbound формат

### Применение в ConfigBuilder

После парсинга всех подписочных нод:

1. **Overrides**: для каждого custom_node с `override` — найти подписочную ноду по тегу, deep merge поля поверх, заменить тег на `tag`
2. **Manual nodes**: custom_node без `override` — добавить как отдельный outbound в allNodes

### UI

#### Long press на ноде → контекстное меню:
- Ping
- Use this node
- Copy name
- **Copy link** (URI формат)
- **Edit** → JSON editor с outbound'ом
- **Reset** (только для overridden нод)

#### Edit screen:
- JSON editor с текущим outbound'ом ноды
- Save → вычисляет diff с оригиналом → сохраняет как override
- Для manual нод — сохраняет полный outbound

#### Add node:
- Из drawer или кнопка "+" на главном экране
- Два варианта:
  - Вставить URI (vless://, vmess://) → парсится в outbound
  - JSON editor с нуля

### Индикация в списке нод

- Нода с override → маленькая иконка карандаша
- Manual нода → иконка звёздочки или пина

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/services/settings_storage.dart` | getCustomNodes/saveCustomNodes |
| `lib/services/config_builder.dart` | Применение overrides + manual nodes |
| `lib/screens/home_screen.dart` | Copy link, Edit в контекстном меню |
| `lib/screens/node_edit_screen.dart` | **Новый** — JSON editor для ноды |
| `lib/widgets/node_row.dart` | Индикация override/manual |

## Критерии приёмки

- [ ] Пользователь может создать ноду вручную (URI или JSON).
- [ ] Пользователь может отредактировать подписочную ноду (порт, сервер, TLS).
- [ ] Изменения сохраняются как override и не теряются при обновлении подписки.
- [ ] Переименование тега работает.
- [ ] Copy link копирует URI ноды в буфер.
- [ ] Overridden ноды визуально отмечены.
- [ ] Reset возвращает ноду к оригиналу из подписки.
