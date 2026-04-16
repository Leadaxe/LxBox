# 027 — Autosave

**Status:** Реализовано

## Контекст

Ранее экраны Routing, VPN Settings и DNS Settings имели кнопку Apply для сохранения изменений. Пользователи забывали нажимать Apply, изменения терялись. Нужен автоматический механизм сохранения без явного действия.

## Реализация

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

void _apply() {
  _saveSettings();
  _regenerateConfig();
}

@override
void dispose() {
  _saveTimer?.cancel();
  super.dispose();
}
```

Паттерн одинаковый для всех трёх экранов.

### Экран Subscriptions

На экране подписок нет отдельных настроек для autosave. Вместо этого при выходе с экрана (через `PopScope`) проверяется флаг `_dirty`. Если подписки изменились (добавление, удаление, toggle enabled, переименование), конфиг регенерируется:

```dart
PopScope(
  onPopInvokedWithResult: (didPop, _) {
    if (_dirty) {
      _regenerateConfig();
    }
  },
  child: ...
)
```

### Поведение

- Изменение любого поля на экране настроек → debounce 500 мс → save + regenerate
- Переключение switch, выбор dropdown, ввод текста — всё триггерит `_scheduleSave()`
- При быстром последовательном вводе сохранение происходит один раз после паузы
- При выходе с экрана `dispose()` отменяет pending таймер (изменения уже применены при последнем fire)

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/routing_screen.dart` | Удалена кнопка Apply, добавлен `_scheduleSave()` debounce |
| `lib/screens/settings_screen.dart` | Удалена кнопка Apply, добавлен `_scheduleSave()` debounce |
| `lib/screens/dns_settings_screen.dart` | Удалена кнопка Apply, добавлен `_scheduleSave()` debounce |
| `lib/screens/subscriptions_screen.dart` | `PopScope` с регенерацией конфига при `_dirty` |

## Критерии приёмки

- [x] Кнопки Apply удалены с экранов Routing, VPN Settings, DNS Settings
- [x] Изменения сохраняются автоматически с debounce 500 мс
- [x] Timer отменяется в `dispose()`
- [x] Subscriptions screen регенерирует конфиг при выходе если были изменения
- [x] Быстрые последовательные изменения не вызывают множественных сохранений
