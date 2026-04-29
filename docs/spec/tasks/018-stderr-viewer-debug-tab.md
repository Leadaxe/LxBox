# 018 — Stderr viewer: вкладка `stderr` в Debug-экране

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-29 |
| Связанные spec'ы | [`038 crash diagnostics`](../features/038%20crash%20diagnostics/spec.md), [`031 debug api`](../features/031%20debug%20api/spec.md) |

## Проблема

`Libbox.redirectStderr` пишет Go panic-stacktrace в `filesDir/stderr.log` до SIGABRT'а — файл переживает смерть процесса. Без UI пользователь не может его достать без `adb pull` или включённого Debug API + adb-forward.

## Решение

### Сервис чтения

[`lib/services/stderr_reader.dart`](../../../app/lib/services/stderr_reader.dart):

```dart
class StderrReader {
  static Future<String?> read();   // null если файл отсутствует/пуст
  static Future<String?> path();   // путь к файлу или null
}
```

Через `path_provider` `getApplicationDocumentsDirectory()` (= Android `filesDir`).

### UI

[`lib/screens/debug_screen.dart`](../../../app/lib/screens/debug_screen.dart) — на `initState` async читает stderr; если непустой — оборачивает экран в `DefaultTabController(length: 2)` с `TabBar`:

- **Log** — текущий контент.
- **stderr** — `SelectableText` (monospace) + кнопки Refresh + Share.

Если файл пустой — экран как раньше, без TabBar.

### Share

- Кнопка на вкладке stderr — `Share.shareXFiles([XFile(stderr.log)])`.
- Кнопка ⤴ в AppBar (`DumpBuilder`) — поле `stderr_log` в JSON-pack рядом с `config + vars + server_lists + debug_log`.

## Verification

- На устройстве без крашей — TabBar отсутствует.
- На устройстве с непустым `stderr.log` — TabBar появляется, content виден, Refresh/Share работают.
