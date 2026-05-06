# 031 — Debug API

> ⚠ **Этот spec замещён.** Содержание перенесено в [§043 Diagnostics platform — Раздел A](../043%20applog%20per-source%20quotas/spec.md#раздел-a--debug-api-was-031).

| Поле | Значение |
|------|----------|
| Статус | ✅ Done — содержание мигрировало в §043 |
| Дата исходная | 2026-04-20 |
| Дата консолидации | 2026-05-06 |
| Заменён на | [`§043 Diagnostics platform`](../043%20applog%20per-source%20quotas/spec.md) |

## Что было здесь

- Локальный HTTP-сервер на `127.0.0.1:9269` с Bearer-auth
- Полная HTTP-API для introspection (`/state`, `/device`, `/config`, `/logs`)
- CRUD на доменные ресурсы (`/rules`, `/subs`, `/settings`)
- Proxy к Clash API (`/clash/*`) с инжекцией auth'а
- Triggers контроллеров (`/action/*`)
- Diagnostics dump endpoints (`/diag/*`)
- Backup export/import (`/backup/*`)
- Anti-DNS-rebinding host check, scoped storage writes, port toggle в App Settings

## Где смотреть сейчас

| Раздел | Где в §043 |
|---|---|
| Цель / Архитектура | [A.1–A.2](../043%20applog%20per-source%20quotas/spec.md#a1-цель) |
| Контракт ответа / DebugError | [A.3](../043%20applog%20per-source%20quotas/spec.md#a3-контракт-ответа) |
| `/ping`, `/help` | [A.4](../043%20applog%20per-source%20quotas/spec.md#a4-эндпоинты--health) |
| `/state/*` | [A.5](../043%20applog%20per-source%20quotas/spec.md#a5-эндпоинты--state-чтение-состояния-контроллеров) |
| `/device` | [A.6](../043%20applog%20per-source%20quotas/spec.md#a6-эндпоинты--device) |
| `/config`, `PUT /config` | [A.7](../043%20applog%20per-source%20quotas/spec.md#a7-эндпоинты--config) |
| `/logs/*`, `/logs/app`, `/logs/core` | [A.8](../043%20applog%20per-source%20quotas/spec.md#a8-эндпоинты--logs) |
| `/clash/*` proxy | [A.9](../043%20applog%20per-source%20quotas/spec.md#a9-эндпоинты--clash-api-proxy-auth-injected) |
| `/action/*` (включая `reset-network`) | [A.10](../043%20applog%20per-source%20quotas/spec.md#a10-эндпоинты--actions-триггеры-контроллеров) |
| CRUD `/rules`, `/subs`, `/settings` | [A.11](../043%20applog%20per-source%20quotas/spec.md#a11-crud-endpoints--доменные-мутации) |
| `/files/*` | [A.12](../043%20applog%20per-source%20quotas/spec.md#a12-files--read-only-file-access) |
| `/diag/*` | [A.13](../043%20applog%20per-source%20quotas/spec.md#a13-diagnostics--diag) |
| `/backup/*` | [A.14](../043%20applog%20per-source%20quotas/spec.md#a14-backup--backup) |
| App Settings UI | [A.17](../043%20applog%20per-source%20quotas/spec.md#a17-ui--app-settings--developer) |
| Storage keys | [A.18](../043%20applog%20per-source%20quotas/spec.md#a18-storage-keys) |
| Безопасность | [A.19](../043%20applog%20per-source%20quotas/spec.md#a19-безопасность) |
| Acceptance | [A.20](../043%20applog%20per-source%20quotas/spec.md#a20-acceptance-раздел-a) |

## Зачем consolidate

§031 (Debug API) + §038 (crash diagnostics) + §043 (AppLog per-source quotas + core logs forwarding) реализационно завязаны друг на друга:

- `/logs/*` endpoints (§031) опираются на per-source split (§043).
- `/diag/applog` (§031) использует `fromPreviousSession` маркер (§038).
- AppLog refactor (§043) трогает persist-формат, который §038 читает на старте.

Single source of truth снижает шанс на рассинхрон между тремя файлами при будущих изменениях.

Файл оставлен как stub (а не удалён) чтобы не ломать существующие cross-ref ссылки в других spec'ах и таскax (`§030 → 031`, `§042 → 031`, `§038 → 031` etc.).
