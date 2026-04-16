# 036 — Sort Modes

**Status:** Реализовано

## Контекст

Пользователю нужна сортировка списка узлов по разным критериям. Ранее было пять режимов (включая desc-варианты), но latencyDesc и nameDesc оказались не востребованы — упрощено до трёх.

## Реализация

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

### Кнопка переключения

Одна кнопка в AppBar, тап циклически переключает режим: `defaultOrder → latencyAsc → nameAsc → defaultOrder → ...`

```dart
IconButton(
  icon: Icon(_sortModeIcon(state.sortMode)),
  onPressed: () => controller.cycleSortMode(),
)
```

### Геттер sortedNodes в HomeState

```dart
List<ProxyNode> get sortedNodes {
  switch (sortMode) {
    case NodeSortMode.defaultOrder:
      return nodes;
    case NodeSortMode.latencyAsc:
      return [...nodes]..sort(_latencyComparator);
    case NodeSortMode.nameAsc:
      return [...nodes]..sort((a, b) => a.name.compareTo(b.name));
  }
}
```

### Сортировка по задержке

Порядок при `latencyAsc`:
1. Узлы с положительной задержкой — по возрастанию
2. Узлы с ошибкой пинга (latency < 0) — после положительных
3. Узлы без пинга (latency == null) — в конце

```dart
int _latencyComparator(ProxyNode a, ProxyNode b) {
  final la = a.latency;
  final lb = b.latency;
  if (la == null && lb == null) return 0;
  if (la == null) return 1;
  if (lb == null) return -1;
  if (la < 0 && lb < 0) return 0;
  if (la < 0) return 1;
  if (lb < 0) return -1;
  return la.compareTo(lb);
}
```

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/models/home_state.dart` | Enum `NodeSortMode`, геттер `sortedNodes`, компаратор |
| `lib/screens/home_screen.dart` | Кнопка сортировки в AppBar, отображение `sortedNodes` |

## Критерии приёмки

- [x] Три режима сортировки: defaultOrder, latencyAsc, nameAsc
- [x] Кнопка циклически переключает режимы
- [x] Иконка соответствует текущему режиму
- [x] Сортировка по задержке: null/no-ping внизу, ошибки после положительных
- [x] Режимы latencyDesc и nameDesc удалены
