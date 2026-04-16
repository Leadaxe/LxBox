# 035 — Traffic Bar and Navigation

**Status:** Реализовано

## Контекст

Пользователю нужна информация о текущем трафике на главном экране без перехода в отдельный экран. Также нужна навигация к детальной статистике и списку соединений.

## Реализация

### Traffic Bar

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

### Навигация

`GestureDetector` оборачивает traffic bar. По тапу открывается `StatsScreen` (экран статистики, см. 024):

```dart
GestureDetector(
  onTap: () => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const StatsScreen()),
  ),
  child: _buildTrafficBar(),
)
```

### StatsScreen → ConnectionsScreen

На экране `StatsScreen` чип "Connections" при тапе открывает `ConnectionsScreen` — полный список активных соединений с кнопками закрытия:

```dart
ActionChip(
  label: Text('Connections'),
  onPressed: () => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const ConnectionsScreen()),
  ),
)
```

`ConnectionsScreen` показывает список соединений с возможностью закрыть отдельное соединение.

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/home_screen.dart` | Traffic bar виджет, GestureDetector навигация |
| `lib/screens/stats_screen.dart` | Чип Connections с навигацией |
| `lib/screens/connections_screen.dart` | Список соединений с кнопками закрытия |

## Критерии приёмки

- [x] Traffic bar отображается под кнопкой Start/Stop
- [x] Показывает upload speed, download speed, connection count, uptime
- [x] Тап по traffic bar открывает StatsScreen
- [x] Чип Connections в StatsScreen открывает ConnectionsScreen
- [x] ConnectionsScreen показывает список с кнопками закрытия соединений
