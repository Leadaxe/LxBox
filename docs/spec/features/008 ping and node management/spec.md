# 008 — Ping & Node Management

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

## Контекст

MVP (Feature 003) предоставлял только одиночный ping по long-press на ноде. Для удобства управления узлами нужны: массовый пинг, визуальная индикация качества связи, настраиваемые параметры пинга.

## Mass Ping

- Кнопка рядом с селектором группы запускает последовательный пинг всех нод текущей группы через Clash API (`/proxies/{tag}/delay`).
- Во время пинга иконка меняется на Stop — нажатие отменяет процесс.
- Epoch-based counter предотвращает race condition при быстрой отмене и повторном запуске.
- Пинг автоматически останавливается при отключении VPN (`tunnelUp` check в цикле).

## Расширенное Long-press меню (NodeRow)

- **Ping** — одиночный пинг ноды.
- **Use this node** — переключение на ноду.
- **Copy outbound JSON** — копирование JSON в буфер обмена.
- Разделитель между действиями и утилитами.

## Цветовая индикация задержки

- `< 200ms` — зелёный.
- `200–500ms` — оранжевый.
- `> 500ms` или ошибка — красный.
- `null` (не пинговалось) / busy — стандартный цвет.

## Ping Settings

**Status:** Реализовано

### Long-press на кнопке пинга

Long-press открывает bottom sheet с настройками пинга. Tooltip с кнопки пинга удалён.

### Bottom Sheet

```
┌──────────────────────────────────┐
│  Ping Settings                   │
│                                  │
│  URL Presets                     │
│  [Google 204] [Cloudflare] [Apple]│
│  [Firefox] [Yandex]             │
│                                  │
│  Custom URL                      │
│  ┌──────────────────────────────┐│
│  │ http://...                   ││
│  └──────────────────────────────┘│
│                                  │
│  Timeout (ms)                    │
│  ┌──────────────────────────────┐│
│  │ 5000                        ││
│  └──────────────────────────────┘│
└──────────────────────────────────┘
```

Пресеты URL загружаются из `wizard_template.json` секции `ping_options.presets` как `ChoiceChip` виджеты.

## URLTest Configuration

**Status:** Реализовано

Три переменные в `wizard_template.json → vars`:

| Поле | Дефолт | Описание |
|------|--------|----------|
| `urltest_url` | `http://cp.cloudflare.com/generate_204` | URL для проверки доступности |
| `urltest_interval` | `5m` | Интервал проверки |
| `urltest_tolerance` | `100` | Допуск в мс для переключения узла |

Переменные применяются к preset group `auto-proxy-out` через механизм `@var` подстановки.

## Файлы

| Файл | Изменения |
|------|-----------|
| `controllers/home_controller.dart` | `pingAllNodes()`, `cancelMassPing()`, epoch counter |
| `widgets/node_row.dart` | Расширенное long-press меню, `_delayColor()` |
| `screens/home_screen.dart` | Mass ping button, long-press handler, bottom sheet |
| `assets/wizard_template.json` | Секция `ping_options` с пресетами; urltest vars |
| `screens/settings_screen.dart` | URLTest поля |

## Критерии приёмки

- [x] Mass ping проходит все ноды группы, UI обновляется по мере получения результатов.
- [x] Cancel немедленно обновляет иконку кнопки и прерывает цикл.
- [x] Два параллельных цикла невозможны (epoch guard).
- [x] Long-press меню: Ping, Use, Copy JSON — все действия работают.
- [x] Цвет задержки соответствует диапазонам.
- [x] Long-press на кнопке пинга открывает bottom sheet с настройками.
- [x] ChoiceChip пресеты загружаются из wizard_template.
- [x] URLTest url, interval, tolerance настраиваются в VPN Settings.
