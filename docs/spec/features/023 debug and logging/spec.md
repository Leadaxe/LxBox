# 023 — Debug & Logging

| Поле | Значение |
|------|----------|
| Статус | Частично реализовано |

## Контекст

Для диагностики проблем с VPN-подключением нужны: экран отладки, настройка уровня логирования, просмотр логов sing-box ядра.

## Debug Screen

Экран `DebugScreen`, доступен из drawer. Содержит:

- **Текущий статус VPN** — состояние туннеля (Started/Stopped/Starting/Stopping)
- **Версия приложения** — `pubspec.yaml` version
- **Версия sing-box** — из libbox
- **Конфиг** — ссылка на Config Editor
- **Clash API** — адрес и статус подключения

## Log Level Settings

Переменная `log_level` в wizard_template vars:

| Уровень | Описание |
|---------|----------|
| `trace` | Максимально подробно |
| `debug` | Отладочная информация |
| `info` | Стандартный (по умолчанию) |
| `warn` | Только предупреждения |
| `error` | Только ошибки |
| `fatal` | Только фатальные |
| `panic` | Только паники |

Настраивается на экране VPN Settings (см. 005 config generator → vars).

## Sing-box Log Viewer

### Текущая реализация

Логи sing-box доступны через:
1. `adb logcat` — нативные логи из BoxVpnService
2. Clash API — ограниченная информация

### Планы

- [ ] Встроенный log viewer на Debug screen
- [ ] Фильтрация по уровню
- [ ] Поиск по тексту
- [ ] Экспорт логов (share)
- [ ] Автопрокрутка

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/debug_screen.dart` | Экран отладки |
| `assets/wizard_template.json` | Переменная `log_level` в vars |
| `lib/screens/settings_screen.dart` | Log level dropdown |

## Критерии приёмки

- [x] Debug screen доступен из drawer
- [x] Показывает статус VPN, версии, Clash API
- [x] Log level настраивается в VPN Settings
- [ ] Встроенный log viewer
- [ ] Экспорт логов
