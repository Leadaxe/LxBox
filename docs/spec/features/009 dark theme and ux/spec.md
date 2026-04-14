# 009 — Dark Theme & UX Improvements

## Контекст

Мобильное приложение должно поддерживать тёмную тему (стандарт для Android), а управление нодами — быть удобным: сортировка, pull-to-refresh, быстрый доступ к настройкам.

## Что реализовано

### Dark Theme
- `ThemeMode.system` в `MaterialApp` — тема автоматически следует за системными настройками устройства.
- `ColorScheme.fromSeed(seedColor: Colors.indigo)` для обеих тем (light + dark).
- Material 3 (`useMaterial3: true`).

### Сортировка нод
- Enum `NodeSortMode`: `defaultOrder` → `latencyAsc` → `latencyDesc` → `nameAsc`.
- Геттер `sortedNodes` в `HomeState` — вычисляется на лету, не мутирует исходный список.
- Ноды без пинга уходят вниз при сортировке по задержке. Ноды с ошибкой (`delay < 0`) — после всех валидных.
- Кнопка циклического переключения в заголовке Nodes (иконка `sort` / `sort_by_alpha`).

### Pull-to-refresh
- `RefreshIndicator` обёрнут вокруг `ListView` нод.
- Свайп вниз → `reloadProxies()` (Clash API).

### Улучшения заголовка Nodes
- Счётчик нод `(N)` рядом с текстом "Nodes".
- Кнопка Reload groups перемещена в строку заголовка.
- Long-press на всей области заголовка → навигация в SettingsScreen.
- `HitTestBehavior.opaque` на GestureDetector для надёжного срабатывания.

### Progress banner
- Индикатор прогресса `SubscriptionController` отображается на главном экране (CircularProgressIndicator + текст).

## Файлы

| Файл | Изменения |
|------|-----------|
| `main.dart` | `darkTheme`, `ThemeMode.system` |
| `models/home_state.dart` | `NodeSortMode` enum, `sortedNodes` getter |
| `controllers/home_controller.dart` | `cycleSortMode()` |
| `screens/home_screen.dart` | Sort button, node count, RefreshIndicator, progress banner, Listenable.merge |

## Критерии приёмки

- [x] Тёмная тема применяется автоматически по системным настройкам.
- [x] Сортировка по задержке (↑↓) и имени (A→Z) работает корректно.
- [x] Pull-to-refresh перезагружает группы.
- [x] Long-press на заголовке Nodes открывает Settings.
