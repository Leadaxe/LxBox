# 018 — Stderr viewer: вкладка `stderr` в Debug-экране

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-29 |
| Связанные spec'ы | [`038 crash diagnostics`](../features/038%20crash%20diagnostics/spec.md), [`031 debug api`](../features/031%20debug%20api/spec.md) |

## Проблема

Файл `external/stderr.log` содержит Go panic-stacktrace последней сессии sing-box (`Libbox.redirectStderr` в [`BoxApplication.initializeLibbox`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxApplication.kt) направляет туда Go stderr ещё до SIGABRT'а). Достать его пользователю без компьютера тяжело: на Android 11+ путь `Android/data/<pkg>/files/` скрыт от файловых менеджеров (Scoped Storage), а `adb pull` требует USB-debugging. Через `§031 Debug API` достать можно, но это требует включения toggle + adb-forward + auth-token — обычный пользователь это не настроит.

Нужен способ: **пользователь открыл Debug-экран, увидел вкладку «stderr», прочитал/скопировал/поделился — без подключения к компьютеру**.

## Решение

### Сервис чтения

Новый файл [`lib/services/stderr_reader.dart`](../../../app/lib/services/stderr_reader.dart):

```dart
class StderrReader {
  /// Содержимое stderr.log или null если отсутствует/пуст.
  static Future<String?> read();

  /// Путь к файлу — для Share (или null).
  static Future<String?> path();
}
```

Реализация — через [`path_provider`](https://pub.dev/packages/path_provider) `getExternalStorageDirectory()` и `dart:io` `File`. Не нужен MethodChannel: тот же путь читается уже из [`§031 Debug API`](../features/031%20debug%20api/spec.md) handler'а `_externalFile`, симметрично.

Намеренно показываем **только последнюю сессию** (нет ротации, нет `.old`-копий, не накапливаем историю крашей). Цель — диагностировать ровно текущий/последний инцидент.

### UI

[`lib/screens/debug_screen.dart`](../../../app/lib/screens/debug_screen.dart) расширен:

1. На `initState` async-запускаем `StderrReader.read()` → сохраняем результат в `_stderrText`. Это происходит до первого `build`, поэтому экран сразу рисуется с правильной структурой.
2. Если `_stderrText != null && _stderrText!.isNotEmpty` — оборачиваем тело в `DefaultTabController(length: 2)` с `TabBar` в `AppBar.bottom`:
   - **Log** — текущий контент (events с фильтрами, search, share-dump).
   - **stderr** — `SelectableText` (monospace, 11sp) с содержимым файла; кнопка **Refresh** (повторно читает) и **Share** (отдаёт `stderr.log` через `share_plus`).
3. Если файла нет / он пустой — экран остаётся как сейчас, **без TabBar**. Вкладка «stderr» не появляется на устройствах, где никогда не было краша.

### Share

`Share.shareXFiles([XFile(stderr.log)], subject: 'L×Box stderr — <iso-time>')`. Существующий `share_plus` уже в зависимостях (используется в `_shareDump`).

В отличие от Share-dump'а (config + vars + subs + log), здесь делимся **только** stderr-файлом — компактнее и без раскрытия пользовательского конфига (важно: stderr содержит имена outbound'ов, иногда host'ы, но не пароли — Go panic пишет stack-frames с локальными переменными, не входной JSON).

## Verification

- На устройстве без крашей — TabBar отсутствует, экран Debug выглядит как до правок.
- На устройстве с непустым `stderr.log` — TabBar появляется, во второй вкладке виден текст, Refresh перечитывает, Share открывает системный диалог.
- На вкладке Log — все существующие фильтры/search/share-dump работают как раньше.
