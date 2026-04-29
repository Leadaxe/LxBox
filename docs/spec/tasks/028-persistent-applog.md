# 028 — Persistent AppLog (file-backed ring-buffer)

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-29 |
| Связанные spec'ы | [`038 crash diagnostics`](../features/038%20crash%20diagnostics/spec.md), [`023 debug and logging`](../features/023%20debug%20and%20logging/spec.md) |

## Проблема

`AppLog` живёт в памяти, при крахе процесса теряется. Pre-crash JVM-events (warning'и парсера, error'ы перед `Libbox.newService`) после рестарта недоступны — `DumpBuilder.debug_log` показывает только пост-рестарт. Это критично для диагностики нативных крахов **до** `Libbox.setup` (когда `stderr.log` ещё не открыт): без persistent JVM-лога мы не видим что приложение делало в момент смерти.

## Решение

### Persistence

Только `warning` + `error` уровни (debug/info остаются in-memory — шум, бессмысленный после рестарта).

- **Файл**: `getApplicationDocumentsDirectory()/applog.txt`, JSON-lines.
- **Cap**: 200 entries или ~64KB — что меньше; обрезается с конца (старые сначала).
- **Write**: rewrite файла через `Future.microtask` с debounce-флагом. При каждом новом warning/error выставляется `_persistDirty = true` и шедулится write; если уже идёт — ставится в очередь через флаг, после завершения первой записи запускается следующая (с актуальным состоянием). Spam'ы warning'ов сводятся в один rewrite.
- **Read**: на старте `main()` зовётся `AppLog.I.initPersistent()` → entries из файла загружаются в `_entries` с `fromPreviousSession=true`. Live-events после старта попадают на верх через обычный `log()`.

### Изменения

- [`models/debug_entry.dart`](../../../app/lib/models/debug_entry.dart) — поле `bool fromPreviousSession` (default `false`).
- [`services/app_log.dart`](../../../app/lib/services/app_log.dart) — `initPersistent()`, schedule-write, `_writePersistent()`.
- [`main.dart`](../../../app/lib/main.dart) — `await AppLog.I.initPersistent()` перед `runApp`.
- [`screens/debug_screen.dart`](../../../app/lib/screens/debug_screen.dart) — визуальный маркер «↑ prev session» в subtitle entries с `fromPreviousSession=true`.
- [`services/dump_builder.dart`](../../../app/lib/services/dump_builder.dart) — поле `fromPreviousSession` в `_entryJson` (если true).

## Verification

- Спам warning'ов не валит UI — write идёт в фоне, debounce работает.
- Размер файла не превышает cap.
- На рестарте после warning'а — entry виден в Debug-экране с маркером prev session.
- В дампе через ⤴ — те же entries попадают.
