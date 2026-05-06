# 022 — Logcat tail в дампе (канал D)

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-29 |
| Связанные spec'ы | [`038 crash diagnostics`](../features/038%20crash%20diagnostics/spec.md) |

## Проблема

Каналы A (stderr), B (ApplicationExitInfo), C (persistent AppLog) не покрывают system-level логи нашего процесса: `tombstoned` / `DEBUG` (libdebuggerd backtrace до tombstone-файла), `AndroidRuntime` FATAL EXCEPTION (Java throwable со стеком — критично когда AEI не приложил trace на Samsung One UI), `JavaVM` / `art` / `linker` (class-load fails). Канал B недоступен на API <30; нужен независимый источник.

## Решение

- **Native MethodChannel `getLogcatTail`** в [`VpnPlugin.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt) → `ProcessBuilder("logcat", "-d", "-t", N, "*:L")` с timeout 2s. `count` clamp 50..5000, default 1000; `level` default `E` (Error+Fatal).
- **Без `READ_LOGS`**: logd UID-фильтрует автоматически — отдаются только события нашего UID + связанные system messages (`tombstoned`/`DEBUG`/`AM died` пишутся под нашим pid).
- **Dart-сервис** [`LogcatReader.tail()`](../../../app/lib/services/logcat_reader.dart) — обёртка над MethodChannel.
- **Интеграция**: поле `logcat_tail` в [`DumpBuilder.build()`](../../../app/lib/services/dump_builder.dart). Также `GET /diag/logcat?count=N&level=L` ([§031](../features/031%20debug%20api/spec.md)).

## Verification

- На любом Android ≥9 — поле `logcat_tail` непустое после краха.
- Async через MethodChannel, UI не блокирует. Timeout 2s страхует от зависания на проблемных ROM.
