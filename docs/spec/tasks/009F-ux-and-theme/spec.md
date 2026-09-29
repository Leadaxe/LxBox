# 009 — UX and Theme

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

## Контекст

Мобильное приложение должно поддерживать тёмную тему (стандарт для Android), а управление нодами — быть удобным: pull-to-refresh, быстрый доступ к настройкам, автосохранение.

## Dark Theme

- `ThemeMode.system` в `MaterialApp` — тема автоматически следует за системными настройками устройства.
- `ColorScheme.fromSeed(seedColor: Colors.indigo)` для обеих тем (light + dark).
- Material 3 (`useMaterial3: true`).

## Pull-to-refresh

- `RefreshIndicator` обёрнут вокруг `ListView` нод.
- Свайп вниз → `reloadProxies()` (Clash API).

## Улучшения заголовка Nodes

- Счётчик нод `(N)` рядом с текстом "Nodes".
- Кнопка Reload groups перемещена в строку заголовка.
- Long-press на всей области заголовка → навигация в SettingsScreen.
- `HitTestBehavior.opaque` на GestureDetector для надёжного срабатывания.

## Progress banner

- Индикатор прогресса `SubscriptionController` отображается на главном экране (CircularProgressIndicator + текст).

## Autosave

**Status:** Реализовано

### Удаление кнопок Apply

Кнопки Apply удалены из AppBar на экранах:
- `RoutingScreen`
- `SettingsScreen` (VPN Settings)
- `DnsSettingsScreen`

### Debounce-механизм

При каждом изменении настройки вызывается `_scheduleSave()`. Внутри — debounce-таймер на 500 мс. Если пользователь продолжает вносить изменения, таймер сбрасывается. Когда пользователь остановился на 500 мс, срабатывает `_apply()`.

```dart
Timer? _saveTimer;

void _scheduleSave() {
  _saveTimer?.cancel();
  _saveTimer = Timer(const Duration(milliseconds: 500), _apply);
}
```

Паттерн одинаковый для всех трёх экранов.

### Экран Subscriptions

При выходе с экрана (`PopScope`) проверяется флаг `_dirty`. Если подписки изменились, конфиг регенерируется.

## Файлы

| Файл | Изменения |
|------|-----------|
| `main.dart` | `darkTheme`, `ThemeMode.system` |
| `screens/home_screen.dart` | Node count, RefreshIndicator, progress banner, Listenable.merge |
| `screens/routing_screen.dart` | Удалена кнопка Apply, добавлен `_scheduleSave()` debounce |
| `screens/settings_screen.dart` | Удалена кнопка Apply, добавлен `_scheduleSave()` debounce |
| `screens/dns_settings_screen.dart` | Удалена кнопка Apply, добавлен `_scheduleSave()` debounce |
| `screens/subscriptions_screen.dart` | `PopScope` с регенерацией конфига при `_dirty` |

## Критерии приёмки

- [x] Тёмная тема применяется автоматически по системным настройкам.
- [x] Pull-to-refresh перезагружает группы.
- [x] Long-press на заголовке Nodes открывает Settings.
- [x] Кнопки Apply удалены с экранов Routing, VPN Settings, DNS Settings.
- [x] Изменения сохраняются автоматически с debounce 500 мс.
- [x] Subscriptions screen регенерирует конфиг при выходе если были изменения.
