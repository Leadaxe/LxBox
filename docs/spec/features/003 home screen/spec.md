# 003 — Главный экран: группы, узлы, навигация

| Поле | Значение |
|------|----------|
| Статус | Реализовано |
| MVP | [`../002%20mvp%20scope/spec.md`](../002%20mvp%20scope/spec.md) |
| Стек / bridge | [`../001%20mobile%20stack/spec.md`](../001%20mobile%20stack/spec.md) |

## 1. Допущения

- Блок **`experimental.clash_api`** в конфиге **предполагается всегда** присутствующим и пригодным; отдельные экраны «включите API в конфиге» **не делаем**.
- Список групп и узлов строится через **HTTP API в стиле Clash** (sing-box *experimental* Clash API).

## 2. Источник данных

| Действие | Смысл |
|----------|--------|
| Проверка API | Запрос живости (например версия), при необходимости повторы. |
| Список в группе | `GET` прокси по имени selector-группы → узлы, активный. |
| Переключение | `PUT` выбора outbound в группе. |
| Ping | `GET` delay для имени outbound (параметры по умолчанию sing-box / без отдельного UI настроек URL в MVP). |

Детали путей — версия sing-box; инкапсуляция в доменном сервисе.

## 3. Селектор группы

- Группы: outbound'ы с `type: selector` (`tag`); значение по умолчанию — из `route.final`, если указывает на selector, иначе первый из списка; если пусто — fallback (например `proxy-out`) на усмотрение реализации.
- Смена группы — перезагрузка списка узлов для этой группы.

## 4. Список узлов

- Строка: имя (отображаемое по данным API), индикация **активного** узла, кнопка **переключить** (или tap по строке), кнопка **ping** — только **одиночный** запрос delay.
- Обновление списка при смене группы и после успешного switch; при обновлении с сервера можно сохранять последний известный delay по имени узла.

## 5. Node Context Menu (long-press)

**Status:** Реализовано

Long-press на `NodeRow` показывает popup menu:

| Пункт | Действие |
|-------|----------|
| **Ping** | Запускает пинг конкретного узла |
| **Use this node** | Переключает текущий outbound на выбранный узел через Clash API |
| **Copy outbound JSON** | Сериализует proxy entry в JSON и копирует в буфер обмена |

```dart
showMenu(
  context: context,
  position: RelativeRect.fromLTRB(dx, dy, dx, dy),
  items: [
    PopupMenuItem(value: 'ping', child: Text('Ping')),
    PopupMenuItem(value: 'use', child: Text('Use this node')),
    PopupMenuItem(value: 'copyJson', child: Text('Copy outbound JSON')),
  ],
);
```

## 6. Traffic Bar and Navigation

**Status:** Реализовано

Панель располагается ниже кнопки Start/Stop на главном экране. Отображает четыре метрики:

```
┌──────────────────────────────────┐
│   ↑ 1.2 MB/s  ↓ 5.4 MB/s       │
│   🔗 42 connections  ⏱ 01:23:45 │
└──────────────────────────────────┘
```

| Метрика | Источник |
|---------|----------|
| Upload speed | Clash API traffic endpoint |
| Download speed | Clash API traffic endpoint |
| Connection count | Clash API connections endpoint |
| Uptime | Таймер с момента запуска VPN |

`GestureDetector` оборачивает traffic bar. По тапу открывается `StatsScreen` (экран статистики, см. 016).

## 7. Sort Modes

**Status:** Реализовано

### Enum NodeSortMode

```dart
enum NodeSortMode {
  defaultOrder,  // Порядок из подписки
  latencyAsc,    // По задержке (возрастание)
  nameAsc,       // По имени (A→Z)
}
```

Каждому режиму соответствует иконка:

| Режим | Иконка |
|-------|--------|
| `defaultOrder` | `Icons.swap_vert` |
| `latencyAsc` | `Icons.signal_cellular_alt` |
| `nameAsc` | `Icons.sort_by_alpha` |

Одна кнопка в AppBar, тап циклически переключает режим: `defaultOrder → latencyAsc → nameAsc → defaultOrder → ...`

### Сортировка по задержке

Порядок при `latencyAsc`:
1. Узлы с положительной задержкой — по возрастанию
2. Узлы с ошибкой пинга (latency < 0) — после положительных
3. Узлы без пинга (latency == null) — в конце

## 8. Node Filter for Auto-Proxy Group

**Status:** Реализовано

Экран с полным списком нод и чекбоксами. По умолчанию все включены. Пользователь снимает галочки с ненужных. Исключённые ноды не попадают в конфиг при генерации.

### Хранение

В `SharedPreferences`:

```json
"excluded_nodes": ["tag1", "tag2", "tag3"]
```

Хранятся только **исключённые** теги (инвертированная логика — по умолчанию всё включено).

### Применение в ConfigBuilder

В `_buildPresetOutbounds`:
- Загрузить `excluded_nodes` из настроек
- Отфильтровать `allNodes` — убрать ноды с тегами из excluded
- Не генерировать outbound для исключённых нод

### UI — Node Filter Screen

```
┌──────────────────────────────────┐
│  ← Node Filter        Select All │
│                                  │
│  ┌──────────────────────────┐    │
│  │ 🔍 Search nodes...      │    │
│  └──────────────────────────┘    │
│                                  │
│  ☑ 🇺🇸 US-Server-1    45ms      │
│  ☑ 🇩🇪 DE-Server-2    82ms      │
│  ☐ 🇷🇺 RU-Server-3    210ms     │
│  ☑ 🇳🇱 NL-Server-4    67ms      │
│  ☐ 🇬🇧 UK-Server-5    timeout   │
│  ...                             │
│                                  │
│  Included: 45 / 52 nodes        │
│                                  │
│  [  Apply & Regenerate Config  ] │
└──────────────────────────────────┘
```

**Функциональность:**
- Чекбокс на каждой ноде (включена/исключена)
- Поиск по имени ноды
- Кнопки: Select All / Deselect All
- Счётчик включённых/всего
- При Apply — сохраняет excluded list, пересобирает конфиг

### Поведение при обновлении подписки

- Новые ноды — включены по умолчанию (их нет в excluded)
- Удалённые ноды — автоматически пропадут
- Переименованные ноды — потеряют excluded статус (по тегу), это ок

## 9. Ошибки и состояния

- Ядро не запущено / API не отвечает — короткие тексты, блокировка операций, требующих API.
- Ошибки ping/switch — нормализовать (см. [`001`](../001%20mobile%20stack/spec.md)).

## 10. Границы слоёв

- UI не ходит в libbox напрямую; Clash API — через домен и клиент HTTP (native или Dart), согласно архитектуре.

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/home_screen.dart` | Traffic bar, sort button, node count, RefreshIndicator, progress banner |
| `lib/models/home_state.dart` | `NodeSortMode` enum, `sortedNodes` getter |
| `lib/controllers/home_controller.dart` | `cycleSortMode()` |
| `lib/widgets/node_row.dart` | Long-press handler, popup menu, `_delayColor()` |
| `lib/screens/node_filter_screen.dart` | Список нод с чекбоксами |
| `lib/services/settings_storage.dart` | getExcludedNodes / saveExcludedNodes |
| `lib/services/config_builder.dart` | Фильтрация allNodes по excluded |

## Критерии приёмки

- [x] Группа выбирается, список узлов и активный отображаются.
- [x] Переключение узла работает и отражается в UI.
- [x] Одиночный ping показывает задержку или ошибку.
- [x] Long-press на узле показывает popup menu (Ping, Use, Copy JSON).
- [x] Traffic bar отображается с upload/download speed, connections, uptime.
- [x] Тап по traffic bar открывает StatsScreen.
- [x] Три режима сортировки: defaultOrder, latencyAsc, nameAsc.
- [x] Node Filter: чекбоксы, поиск, Select All/Deselect All, Apply.
- [x] Исключённые ноды не попадают в конфиг.
