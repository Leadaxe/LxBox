# 043 — Paste Dialog (Smart Clipboard Import)

## Статус: В работе

## Контекст

При вставке из буфера обмена пользователь не знает, что именно будет добавлено. Нужен диалог подтверждения, который автоматически определяет тип содержимого и показывает превью.

## Поддерживаемые форматы

| Тип | Определение | Превью |
|-----|------------|--------|
| Subscription URL | `http://` или `https://` | URL, hostname |
| Direct link | `vless://`, `vmess://`, `trojan://`, `ss://`, `hy2://`, `ssh://`, `socks://`, `wireguard://` | Протокол, сервер:порт, label |
| WireGuard INI config | Содержит `[Interface]` и `[Peer]` | "WireGuard config", endpoint |
| JSON outbound | Начинается с `{` или `[`, содержит `"type"` | Тип, tag, количество outbound'ов |
| Неизвестный | Ничего из выше | Ошибка с превью текста |

## UI: Диалог

### Распознанный формат

```
┌─────────────────────────────┐
│  Add from clipboard         │
│                             │
│  Detected: VLESS link       │
│  🇫🇮 Финляндия-bypass       │
│  fi-m247-01.com:443         │
│                             │
│  [Cancel]        [Add]      │
└─────────────────────────────┘
```

### JSON outbound (один или массив)

```
┌─────────────────────────────┐
│  Add from clipboard         │
│                             │
│  Detected: Outbound JSON    │
│  2 outbounds (vless + socks)│
│                             │
│  [Cancel]        [Add]      │
└─────────────────────────────┘
```

### Нераспознанный формат

```
┌─────────────────────────────┐
│  Add from clipboard         │
│                             │
│  ⚠ Unknown format           │
│  "some garbage text..."     │
│                             │
│           [OK]              │
└─────────────────────────────┘
```

## UI: Поле ввода

Текущее:
- TextField + кнопка Paste + большая кнопка Add

Новое:
- TextField + компактная круглая кнопка `+` (FloatingActionButton.small или IconButton)
- Кнопка Paste убрана (есть в popup menu "Paste from clipboard")

## Реализация

### ClipboardAnalyzer

Утилита для определения типа содержимого буфера:

```dart
class ClipboardContent {
  final String type; // 'subscription', 'direct', 'wireguard_config', 'json_outbound', 'unknown'
  final String title; // "VLESS link", "Subscription URL", etc.
  final String subtitle; // server:port, hostname, outbound count
  final String rawText;
}
```

### _pasteFromClipboard в subscriptions_screen.dart

1. Читает буфер
2. Вызывает ClipboardAnalyzer
3. Показывает диалог с превью
4. По кнопке Add — вызывает addFromInput

### addFromInput — поддержка JSON outbound

Добавить распознавание JSON:
- `{...}` — один outbound → сохранить как connection (JSON строка)
- `[{...}, {...}]` — массив → каждый outbound отдельно или как группу

JSON outbound сохраняется в ProxySource.connections как сериализованный JSON. ConfigBuilder при сборке добавляет его напрямую в outbounds/endpoints.

## Файлы

| Файл | Изменения |
|------|-----------|
| `subscriptions_screen.dart` | Убрать кнопку Paste, Add → круглая `+`, paste dialog |
| `subscription_controller.dart` | Поддержка JSON outbound в addFromInput |
| `config_builder.dart` | Обработка JSON outbound из connections |

## Критерии приёмки

- [ ] Кнопка Paste убрана из поля ввода
- [ ] Кнопка Add заменена на круглую `+`
- [ ] "Paste from clipboard" в popup menu показывает диалог
- [ ] Диалог определяет тип: subscription/direct/WG config/JSON outbound
- [ ] Превью показывает протокол, сервер, label
- [ ] Для JSON — показывает тип и количество outbound'ов
- [ ] Для неизвестного — показывает ошибку с текстом
- [ ] JSON outbound добавляется и работает в конфиге
- [ ] JSON массив с detour добавляется корректно
