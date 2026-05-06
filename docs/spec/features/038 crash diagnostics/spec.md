# 038 — Crash diagnostics

> ⚠ **Этот spec замещён.** Содержание перенесено в [§043 Diagnostics platform — Раздел B](../043%20applog%20per-source%20quotas/spec.md#раздел-b--crash-diagnostics-was-038).

| Поле | Значение |
|------|----------|
| Статус | ✅ Done (MVP1 + MVP2) — содержание мигрировало в §043 |
| Дата исходная | 2026-04-29 |
| Дата консолидации | 2026-05-06 |
| Заменён на | [`§043 Diagnostics platform`](../043%20applog%20per-source%20quotas/spec.md) |

## Что было здесь

Четыре канала post-mortem диагностики без `adb`:

- **Канал A — stderr-redirect** через `Libbox.redirectStderr` → `filesDir/stderr.log` (Go panic stacktrace)
- **Канал B — ApplicationExitInfo** (API 30+) через `getHistoricalProcessExitReasons` (NATIVE_CRASH tombstone, JVM stack, ANR/LMK)
- **Канал C — Persistent AppLog** — warning+error на диск, выживает рестарт (расширен в §043 на dual file: `applog.txt` + `corelog.txt`)
- **Канал D — Logcat tail** через `Runtime.exec("logcat -d")` (UID-фильтрованный logd-buffer)

Плюс HTTP API `/diag/*` группа в Debug API (`/diag/dump`, `/diag/exit-info`, `/diag/logcat`, `/diag/stderr`, `/diag/applog`).

## Где смотреть сейчас

| Канал / тема | Где в §043 |
|---|---|
| Цель + общая архитектура 4 каналов | [B.1–B.2](../043%20applog%20per-source%20quotas/spec.md#b1-цель) |
| Канал A (stderr-redirect) | [B.3](../043%20applog%20per-source%20quotas/spec.md#b3-канал-a--stderr-viewer) |
| Канал B (ApplicationExitInfo) | [B.4](../043%20applog%20per-source%20quotas/spec.md#b4-канал-b--applicationexitinfo) |
| Канал C (Persistent AppLog, расширен в §043) | [B.5](../043%20applog%20per-source%20quotas/spec.md#b5-канал-c--persistent-applog-file-backed-ring-buffer) + [Раздел C](../043%20applog%20per-source%20quotas/spec.md#раздел-c--applog-per-source-quotas--core-logs-pump-original-043) |
| Канал D (Logcat tail) | [B.6](../043%20applog%20per-source%20quotas/spec.md#b6-канал-d--logcat-tail) |
| Безопасность 4 каналов | [B.7](../043%20applog%20per-source%20quotas/spec.md#b7-безопасность-раздел-b) |
| Сводка реализации + tasks | [B.8](../043%20applog%20per-source%20quotas/spec.md#b8-сводка-реализации) |
| HTTP `/diag/*` endpoints | [A.13](../043%20applog%20per-source%20quotas/spec.md#a13-diagnostics--diag) |

## Связанные tasks (без изменений)

- [018 stderr-viewer-debug-tab](../../tasks/018-stderr-viewer-debug-tab.md) — Канал A
- [022 logcat-tail-in-dump](../../tasks/022-logcat-tail-in-dump.md) — Канал D
- [028 persistent-applog](../../tasks/028-persistent-applog.md) — Канал C (расширен в §043)
- [029 application-exit-info](../../tasks/029-application-exit-info.md) — Канал B

## Зачем consolidate

§038 (Persistent AppLog) и §043 (per-source quotas + core forwarding) делят один и тот же файл `app/lib/services/app_log.dart` и persist-формат. §038 + §031 пересекаются в `/diag/*` HTTP API. Держать три раздельных spec'а с встречными cross-ref'ами — рассинхрон-prone.

Файл оставлен как stub (не удалён) чтобы не ломать существующие ссылки из других spec'ов и task'ов.
