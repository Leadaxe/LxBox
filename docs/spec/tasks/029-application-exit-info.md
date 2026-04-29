# 029 — ApplicationExitInfo reader (lazy в DumpBuilder)

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-29 |
| Связанные spec'ы | [`038 crash diagnostics`](../features/038%20crash%20diagnostics/spec.md) |

## Проблема

Если краш — нативный SIGABRT/SIGSEGV до `Libbox.redirectStderr` (либо в самом `Libbox.setup`, либо в JNI-glue, либо в `dlopen libbox.so`) — Go runtime ничего не пишет в stderr (канал A пуст). `getHistoricalProcessExitReasons` (Android 11+) хранит причину exit'а от системы с tombstone'ом для NATIVE_CRASH — это и есть ground-truth «что убило процесс». Без него такие краши неотличимы.

## Решение

- **Native MethodChannel `getApplicationExitInfo`** в [`VpnPlugin.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt) → `ActivityManager.getHistoricalProcessExitReasons(pkg, 0, 5)` с маппингом `REASON_*` → читаемые имена (`CRASH | CRASH_NATIVE | ANR | LOW_MEMORY | SIGNALED | …`). На API <30 — пустой список. Каждая запись: `{timestamp, reason, description, importance, pss, rss, status, trace}`. `trace` читается из `traceInputStream` (mini-tombstone для NATIVE_CRASH).
- **Dart-сервис** [`ExitInfoReader.read()`](../../../app/lib/services/exit_info_reader.dart) — обёртка над MethodChannel; на исключения возвращает пустой список.
- **Интеграция**: поле `exit_info` в [`DumpBuilder.build()`](../../../app/lib/services/dump_builder.dart). Также доступно через `GET /diag/exit-info` ([§031](../features/031%20debug%20api/spec.md)).

## Почему lazy в DumpBuilder

- `traceInputStream` для NATIVE_CRASH может быть до сотен KB — не нужен sync IO на cold-start.
- В дампе всегда свежее состояние (не cached snapshot со старта).
- Никакого persistent reader'а, lifecycle, дедупликации.

## Verification

- На API <30 — `exit_info: []`, никаких ошибок.
- На API 30+ после краха — в дампе виден `reason: "CRASH_NATIVE"` (или соответствующий) с непустым `trace` (mini-tombstone).
- При нормальном lifecycle — могут быть entries с `reason: "USER_REQUESTED"` / `"SIGNALED"` от прошлых force-stop'ов; это OK, не маскируем.
