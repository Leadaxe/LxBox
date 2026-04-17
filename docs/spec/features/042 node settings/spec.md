# 042 — Node Settings (Detour & Tag)

## Статус: Спека

## Контекст

В списке Servers два типа записей, которые сейчас выглядят одинаково:

### Подписка (subscription URL)
- Источник: `https://provider.com/sub/xxx`
- Содержит N нод, периодически обновляется
- Ноды управляются провайдером — редактировать нельзя
- `ProxySource.source` непустой, `ProxySource.connections` пустой
- Тап → экран деталей подписки (SubscriptionDetailScreen)

### Прямой сервер (direct link / config)
- Источник: `vless://...`, `wireguard://...`, INI конфиг
- Содержит 1 ноду, статичная
- Полностью под контролем пользователя — можно менять настройки
- `ProxySource.source` пустой, `ProxySource.connections` непустой
- Тап → экран настроек ноды (NodeSettingsScreen) — **новый**

## Визуальное различие

Различие в trailing (правая часть ListTile):

| Тип | Trailing | Пример |
|-----|----------|--------|
| Подписка (N нод) | Chip с количеством | `[12]` |
| Подписка (0 нод) | Ничего | — |
| Прямой сервер | Иконка сервера | `🖥` (Icons.dns) |

Leading (слева) — Switch вкл/выкл — одинаковый для обоих.

### Как определить тип

```dart
final isDirectServer = entry.source.source.isEmpty 
    && entry.source.connections.isNotEmpty;
```

### Изменения в _buildList

```dart
// trailing:
trailing: isDirectServer
    ? Icon(Icons.dns, size: 20, color: cs.onSurfaceVariant)
    : entry.nodeCount > 0
        ? Chip(label: Text('${entry.nodeCount}'), ...)
        : null,

// onTap:
onTap: () => Navigator.push(context, MaterialPageRoute(
  builder: (_) => isDirectServer
      ? NodeSettingsScreen(entry: entry, index: i, ...)
      : SubscriptionDetailScreen(entry: entry, ...),
)),
```

## Экран настроек ноды (NodeSettingsScreen)

### Заголовок
AppBar: имя ноды (текущий tag или label)

### Секция: Основное

**Tag (название ноды)**

```
TextField: "wg-parnas"
```

Подпись: "Display name of this node. Used in proxy groups and statistics."

Tag — уникальный идентификатор ноды в sing-box. Отображается на главном экране, в статистике, в выборе detour. Пользователь может дать понятное имя вместо автогенерированного.

### Секция: Routing

**Detour (цепочка серверов)**

```
DropdownButton: [None (direct)] / node-a / node-b / wg-parnas / ...
```

Подпись: "Route traffic through another server before reaching this one. Creates a multi-hop chain for extra privacy or to bypass restrictions."

Пример в UI:

```
┌─────────────────────────────────────────┐
│  Detour                                 │
│  ┌──────────────────────────────────┐   │
│  │ wg-parnas                      ▼ │   │
│  └──────────────────────────────────┘   │
│  Traffic to this server will first go   │
│  through "wg-parnas", then to this      │
│  server, then to the internet.          │
│                                         │
│  Phone → wg-parnas → this server → Web  │
└─────────────────────────────────────────┘
```

Список detour-вариантов:
- "None (direct)" — без цепочки, прямое соединение
- Все ноды из всех источников (подписки + прямые серверы), кроме самой себя
- Показывать только теги нод, не группы

### Секция: Info (read-only)

| Поле | Пример |
|------|--------|
| Protocol | wireguard |
| Server | 212.232.78.237:51820 |
| URI | tap to reveal |

## Хранение

Переопределения хранятся в `boxvpn_settings.json` через SettingsStorage:

```json
{
  "node_overrides": {
    "original-tag": {
      "custom_tag": "my-vpn-germany",
      "detour": "wg-parnas"
    }
  }
}
```

- `original-tag` — исходный tag ноды (из парсинга URI)
- `custom_tag` — пользовательское имя (если пустое — используется оригинальное)
- `detour` — tag ноды для цепочки (если пустое — нет detour)

### SettingsStorage API

```dart
static Future<Map<String, Map<String, String>>> getNodeOverrides() async { ... }
static Future<void> saveNodeOverride(String originalTag, {String? customTag, String? detour}) async { ... }
static Future<void> removeNodeOverride(String originalTag) async { ... }
```

## ConfigBuilder

При сборке конфига, после создания outbound'ов из нод:

1. Загрузить `node_overrides`
2. Для каждого override:
   - Если `custom_tag` непустой — переименовать tag outbound'а и все ссылки на него в группах
   - Если `detour` непустой — добавить `"detour": "detour-tag"` в outbound

```dart
void _applyNodeOverrides(Map<String, dynamic> config, Map<String, Map<String, String>> overrides) {
  final outbounds = config['outbounds'] as List<dynamic>;
  final endpoints = config['endpoints'] as List<dynamic>? ?? [];
  
  for (final ob in [...outbounds, ...endpoints]) {
    final tag = ob['tag'] as String?;
    if (tag == null || !overrides.containsKey(tag)) continue;
    final ov = overrides[tag]!;
    
    if (ov['detour']?.isNotEmpty == true) {
      ob['detour'] = ov['detour'];
    }
    if (ov['custom_tag']?.isNotEmpty == true) {
      // Rename tag and update all references in groups
      final newTag = ov['custom_tag']!;
      _renameTag(config, tag, newTag);
    }
  }
}
```

## Autosave

Как на всех экранах настроек — debounce 500ms, без кнопки Apply.

## Файлы

| Файл | Изменения |
|------|-----------|
| `subscriptions_screen.dart` | Различие trailing (Chip vs Icon), разный onTap для подписок и серверов |
| `node_settings_screen.dart` | **Новый**: tag, detour dropdown, info, autosave |
| `settings_storage.dart` | `getNodeOverrides`, `saveNodeOverride`, `removeNodeOverride` |
| `config_builder.dart` | `_applyNodeOverrides` — tag rename + detour |

## SubscriptionDetailScreen — контекстное меню нод

В списке нод внутри подписки (SubscriptionDetailScreen) — добавить long press на каждую ноду:

### Контекстное меню

| Пункт | Действие |
|-------|----------|
| Copy node info | Копирует `scheme://server:port#label` |
| Copy tag | Копирует tag ноды |

### Визуальное выделение

Ноды из прямых connections (не из подписки URL) визуально отличаются — например иконкой или цветом trailing, чтобы было видно что это отдельное соединение добавленное вручную.

Определение: если `ProxySource.source` пустой и `ProxySource.connections` непустой — все ноды являются прямыми connections.

## Критерии приёмки

- [ ] Подписки показывают Chip с количеством нод справа
- [ ] Прямые серверы показывают иконку сервера справа
- [ ] Тап на подписку → SubscriptionDetailScreen (как раньше)
- [ ] Тап на прямой сервер → NodeSettingsScreen
- [ ] Можно изменить tag (название ноды)
- [ ] Можно выбрать detour из списка всех нод
- [ ] Понятный комментарий про detour с визуальной схемой цепочки
- [ ] "None (direct)" как вариант без цепочки
- [ ] Нельзя выбрать саму себя как detour
- [ ] Autosave с debounce 500ms
- [ ] Overrides применяются в ConfigBuilder
- [ ] Переименованная нода отображается с новым именем на главном экране
- [ ] Detour добавляется в outbound/endpoint при сборке конфига
