# 006 — UI подписок и настроек (Servers)

| Поле | Значение |
|------|----------|
| Статус | Реализовано |
| Зависимости | [`004`](../004%20subscription%20parser/spec.md), [`005`](../005%20config%20generator/spec.md) |

## 1. Цель

Мобильный UI для управления подписками (добавление, удаление, обновление) и настройками (переменные из wizard template), с автоматической перегенерацией конфига.

## 2. Экран подписок (Subscriptions)

### 2.1 Список подписок

Каждая подписка отображается как карточка:
- URL (или «Direct link» для прямых ссылок)
- Количество распарсенных нод
- Статус: загружена / ошибка / не обновлялась
- Switch вкл/выкл (см. раздел Subscription Toggles)

### 2.2 Добавление подписки

Способы добавления:
1. **URL подписки** — текстовое поле + кнопка «Add»
2. **Вставка из буфера** — кнопка paste, автоопределение: URL подписки или direct link
3. **Direct link** — одиночная ссылка `vless://`, `vmess://` и т.д.

После добавления:
- Если URL — fetch → decode → parse → показать количество нод
- Если direct link — parse → показать имя узла
- При ошибке — сообщение (bad URL, parse error, network error)

### 2.3 Действия

- **Обновить все** — re-fetch всех подписок, перегенерация конфига
- **Удалить** — подтверждение, перегенерация конфига
- **Генерировать конфиг** — явная кнопка для пересборки

### 2.4 Состояние при обновлении

- Прогресс: `Downloading 1/3...`, `Parsing 2/3...`
- Блокировка UI действий во время обновления
- Результат: `Updated: 150 nodes from 3 subscriptions`

## 3. Subscription Detail View

**Status:** Реализовано

**Тап** → открывается detail screen с содержимым подписки.

### Detail Screen

Открывается через `Navigator.push` (полноэкранный роут).

**AppBar:**
- Заголовок: `entry.displayName`
- Кнопка `Edit` (карандаш) → диалог переименования
- Кнопка `Delete` (корзина) → confirm dialog → удаление + pop

**Тело:**

Секция с мета-информацией:
```
URL / source          [текст, selectable, с кнопкой copy]
Последнее обновление  [время, например "2h ago"]
Нод                   [число]
```

Список нод — загружается при открытии из кеша (не HTTP запрос):
- Каждый элемент: иконка протокола + имя ноды (tag)
- Кнопка refresh в AppBar для ручного обновления

### Detail Enhancements

- **Иконка Telegram** (`Icons.telegram`, цвет `#2AABEE`) в списке и detail screen
- **Ссылки** support/web page открываются через UrlLauncher
- **Без автозагрузки** при открытии — данные из кеша

## 4. Subscription Toggles

**Status:** Реализовано

Поле `enabled` (bool, по умолчанию `true`) в модели `ProxySource`. При отключении:
- Текст становится серым
- ConfigBuilder исключает узлы отключённых подписок
- `updateAllAndGenerate()` пропускает отключённые подписки

## 5. Subscription Context Menu

**Status:** Реализовано

Long-press на элементе списка подписок открывает `showModalBottomSheet`:

| Действие | Описание |
|----------|----------|
| **Copy URL** | Копирует URL в буфер обмена |
| **Update** | Запускает обновление конкретной подписки |
| **Delete** | Показывает диалог подтверждения, удаляет |

## 6. Paste Dialog (Smart Clipboard Import)

**Status:** В работе

При вставке из буфера — диалог подтверждения с автоопределением типа содержимого:

| Тип | Определение | Превью |
|-----|------------|--------|
| Subscription URL | `http://` или `https://` | URL, hostname |
| Direct link | `vless://`, `vmess://`, etc. | Протокол, сервер:порт, label |
| WireGuard INI config | `[Interface]` и `[Peer]` | "WireGuard config", endpoint |
| JSON outbound | `{` или `[`, содержит `"type"` | Тип, tag, количество outbound'ов |
| Неизвестный | Ничего из выше | Ошибка с превью текста |

UI: TextField + компактная круглая кнопка `+` (кнопка Paste убрана, есть в popup menu).

## 7. Навигация

Оба экрана доступны из **drawer** на главном экране:

```
Drawer:
  ├── Subscriptions          — управление подписками
  ├── Settings               — переменные и правила
  ├── Config
  │   ├── Editor             — существующий ConfigScreen
  │   ├── Read from file     — (как есть)
  │   └── Paste from clipboard — (как есть)
  └── Debug                  — (как есть)
```

## 7a. Detour settings per subscription

Detail screen → вкладка **Settings** → раздел **Display** содержит три свитча, управляющие поведением ⚙-серверов этой подписки. Раздел скрывается целиком, если в подписке нет ни одной ноды с detour.

| Свитч | Default | Эффект |
|-------|---------|--------|
| Register detour servers | on | ⚙-теги попадают в `allNodeTags` и становятся выбираемыми во всех proxy-группах (`vpn-*`). |
| Register detour in auto group | **off** | Дополнительный фильтр: даже если Register включён — ⚙-теги **не** попадают в члены `auto-proxy-out` (urltest). Защита от автовыбора посредника финальной точкой. |
| Use detour servers | on | Узлы реально соединяются через свой detour. Off → `detour` удаляется у outbound, трафик идёт напрямую. |

Переопределение через секцию **Override** (выбор одного detour для всех нод подписки) — ниже.

Подробности реализации и семантика флагов — в `018 detour server management`.

## 8. Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/subscriptions_screen.dart` | Список, Switch, long-press, paste dialog |
| `lib/screens/subscription_detail_screen.dart` | Detail screen, Telegram, UrlLauncher, rename |
| `lib/models/proxy_source.dart` | Поле `enabled`, `name`, `lastUpdated`, `lastNodeCount`, `displayName` |
| `lib/controllers/subscription_controller.dart` | Фильтрация disabled, metadata |
| `lib/services/config_builder.dart` | Фильтрация disabled источников |

## 9. Критерии приёмки

- [x] Можно добавить подписку по URL и увидеть количество нод.
- [x] Можно добавить direct link и увидеть имя узла.
- [x] Обновление всех подписок скачивает и парсит контент.
- [x] Удаление подписки работает с перегенерацией конфига.
- [x] Тап по подписке открывает detail screen.
- [x] Detail screen показывает URL/source, дату обновления, количество нод, список нод.
- [x] Rename работает в detail screen.
- [x] Switch включает/выключает подписку без удаления.
- [x] Long-press открывает контекстное меню (Copy URL, Update, Delete).
- [x] Навигация из drawer работает.
