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

- Группы: outbound'ы с `type: selector` (`tag`); значение по умолчанию — из `route.final`, если указывает на selector, иначе первый из списка; fallback — `vpn-1` (всегда генерируется).
- Смена группы — перезагрузка списка узлов для этой группы.

## 4. Список узлов

- Строка: имя (отображаемое по данным API), индикация **активного** узла, кнопка **переключить** (или tap по строке), кнопка **ping** — только **одиночный** запрос delay.
- Обновление списка при смене группы и после успешного switch; при обновлении с сервера можно сохранять последний известный delay по имени узла.

### 4.1. NodeRow subtitle layout

```
┌────────────────────────────────────────────────────┐
│ Tag                                                │
│ [ACTIVE✓]  PROTOCOL                          50MS  │
└────────────────────────────────────────────────────┘
                                                ^right-aligned
```

Subtitle строится в `_buildSubtitleRow` (`lib/widgets/node_row.dart`):

| Элемент | Источник | Формат |
|---------|----------|--------|
| `[ACTIVE]` pill | `tag == state.activeInGroup` | Зелёный pill с `tertiaryContainer` фоном, fontSize 9, bold |
| `→ urltestNow` | Для urltest-группы — текущий выбранный узел | `→ BL: Frankfurt`, italic, серый |
| Protocol | `protocolLabel` пропс из `home_screen` (по `outbound['type']`) | `VLESS`, `Hy2`, `WG`, `TUIC`, `SS` etc. **Без `+ TLS` суффикса** — TLS дефолт у большинства, метить = шум. Для urltest-группы — proto **выбранной** ноды |
| Ping | `delay` ms (или `PING…` / `ERR`) | Right-aligned, цвет по latency: `<200ms` зелёный, `<500` оранжевый, `>500`/err красный |

Все элементы flex-Wrap слева, ping абсолютно справа через `Spacer`-Expanded.

## 5. Node Context Menu (long-press)

**Status:** Реализовано

Long-press на `NodeRow` показывает popup menu:

| Пункт | Действие |
|-------|----------|
| **Ping** | Запускает пинг конкретного узла |
| **Use this node** | Переключает текущий outbound на выбранный узел через Clash API |
| **View JSON** | Открывает read-only страницу с форматированным JSON outbound/endpoint. Если у узла есть detour — выдаёт массив `[node, detour1, detour2, ...]` (рекурсивный обход по `detour`) |
| **Copy URI** | Канонический URI: `vless://`, `wireguard://`, `hy2://`, etc через `node.toUri()` (round-trip parser v2). Если NodeSpec не находится по display-tag (control-узел / collision-suffix) — snackbar `No source URI for this node` |
| **Copy server (JSON)** | Копирует outbound узла в JSON (без поля `detour`) |
| **Copy detour** | Копирует только detour-outbound (скрыт для узлов без detour) |
| **Copy server + detour** | Массив `[detour, server]` (скрыт для узлов без detour) |

Для системных строк `direct-out` и `auto-proxy-out` Copy-пункты **скрыты** — это не настоящие серверы.

### Pinned special rows

`direct-out` и `auto-proxy-out` при любой сортировке (latencyAsc / nameAsc) всегда **вверху** списка, в строгом порядке: сначала `direct-out`, потом `auto-proxy-out`. Визуально выделены лёгкой подсветкой фона (`secondaryContainer.withAlpha(40)`).

### Show detour servers

Toggle в popup menu AppBar. По умолчанию **включён** — `⚙ ` серверы (посредники-dialer'ы) видны в списке. Если выключить — строки с префиксом `⚙ ` скрываются.

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

## 8a. Warning "Restart VPN to apply"

Когда пользователь меняет конфиг (routing, settings, подписки) **при работающем туннеле**, в памяти/на диске уже новый конфиг, но туннель крутит старый. Нужно уведомить:

> **Config changed — restart VPN to apply**

Показывается в `_buildControls` под рядом кнопок Start/Stop, розовой плашкой (`tertiaryContainer`). Тап по плашке открывает диалог подтверждения остановки VPN.

### Derived flag

`_needsRestart` — **derived getter**, не mutable bool. Возвращает `true`, если:

```dart
state.tunnelUp && (state.configStaleSinceStart || _subController.configDirty)
```

Где:
- `state.configStaleSinceStart` — sticky-флаг в `HomeState`, ставится в `saveParsedConfig` при `tunnelUp`, сбрасывается на tunnel транзитах (up→connected, down→disconnected/revoked).
- `_subController.configDirty` — settings изменены, конфиг ещё не пересобран (через `persistSources()` / `_persist()`).

### Почему явный флаг, а не diff

Ранний подход сравнивал `state.configRaw` с snapshot'ом, взятым на tunnel up. Хрупко: canonical JSON может совпасть при разных настройках (редко, но возможно), плюс AnimatedBuilder может не поймать промежуточные изменения. Явный флаг в HomeState проще и детерминирован.

### Инварианты

- Гасится **только** реальным tunnel транзитом — не тапами по кнопкам Stop/Cancel. Иначе юзер отменяет Stop-диалог и warning пропадает, хотя рестарт всё ещё нужен.
- Любой путь, который зовёт `HomeController.saveParsedConfig` при `tunnelUp` (Routing Apply, Source import, Debug, Home ⟳), автоматически поднимает флаг. Не нужно пробрасывать setState'ы через виджеты.
- Sticky до следующего `connected` → любая цепочка saveConfig'ов во время работы туннеля схлопывается в один warning.

## 8b. Reload button (справа от status chip)

**Status:** Реализовано

Круглая кнопка с иконкой `refresh` справа от status chip. Иконка читается как «переподключиться», что и является default-поведением. Полный набор действий — через long press.

### Поведение

| Состояние | Short tap (default) | Long press меню |
|-----------|---------------------|-----------------|
| VPN off | Rebuild config + connect | **Connect** / Rebuild config only / Rebuild config + connect |
| VPN on, clean | Reconnect | **Reconnect** / Rebuild config only / Rebuild config + reconnect |
| VPN on, dirty (`_subController.configDirty \|\| _needsRestart`) | Rebuild config + reconnect | то же, что в clean |

Dirty-подсветка: кнопка рисуется с `primaryContainer` фоном (circle) и `onPrimaryContainer` иконкой, чтобы визуально показать что конфиг требует пересборки. Tooltip меняется по состоянию (равен default-label'у).

### Reconnect-цепочка

`HomeController.reconnect()`:

1. Если туннель не up — просто `start()` (меню-пункт «Reconnect» при VPN off = Connect).
2. Иначе: подписаться на `onStatusChanged.firstWhere(disconnected|revoked)` **до** вызова stop (broadcast-stream, чтобы не упустить быстрый event), вызвать `stopVPN`, дождаться (timeout 10 сек), затем `startVPN`.
3. `busy=true` держится на всю цепочку — UI не даст повторно нажать между stop и start.

### Инварианты

- Long-press меню всегда показывает все 3 пункта, даже когда часть из них совпадает с default tap — это намеренно, чтобы поведение было предсказуемым.
- Лейбл «Reconnect» в off-state заменяется на «Connect»; «Rebuild config + reconnect» — на «Rebuild config + connect». Действие одно и то же (`reconnect()` само разветвляется).
- Rebuild всегда очищает `_subController.configDirty` (как и существующий `_rebuildAndClearDirty`). Sticky-флаг `configStaleSinceStart` гасится естественным путём на tunnel-транзите — в новую сессию цикл стартует чистым.

## 9. Ошибки и состояния

- Ядро не запущено / API не отвечает — короткие тексты, блокировка операций, требующих API.
- Ошибки ping/switch — нормализовать (см. [`001`](../001%20mobile%20stack/spec.md)).

## 10. Границы слоёв

- UI не ходит в libbox напрямую; Clash API — через домен и клиент HTTP (native или Dart), согласно архитектуре.

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/home_screen.dart` | Traffic bar, sort button, node count, RefreshIndicator, progress banner, reload button (§8b) |
| `lib/models/home_state.dart` | `NodeSortMode` enum, `sortedNodes` getter |
| `lib/controllers/home_controller.dart` | `cycleSortMode()`, `reconnect()` (§8b) |
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
- [x] Reload button: short tap = reconnect / rebuild+connect / rebuild+reconnect по состоянию; long press = меню из 3 пунктов.
