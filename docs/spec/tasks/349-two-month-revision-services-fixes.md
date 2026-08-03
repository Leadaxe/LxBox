# §349 — Ревизия кода за два месяца: фиксы controllers/services

| | |
|---|---|
| Тип | bugfix (пачка по итогам code review) |
| Статус | ✅ Released v2.19.3 — тесты зелёные |
| Дата | 2026-08-02 |
| Связанные | [`348`](348-two-month-revision-parser-fixes.md) (parser/builder-половина той же ревизии), [`221`](221-backup-export-allowlist-asymmetry.md), [`331`](331-blue-banner-and-manual-refresh-reaction.md), [`337`](337-auto-update-disabled-subscriptions.md), [`325`](325-mass-ping-wipes-other-channels.md), [`238`](238-debug-api-channels-folders.md) |

## Находки и фиксы

### F1 (P1) — `auto_ping_on_start` терялся при restore бэкапа

Единственный var-сирота: писался `setVar`'ом (App Settings → Auto ping on
start), но не входил ни в `_appFeatureFlagVars`, ни в template ⇒ экспорт его
клал (vars нефильтрован), а default-deny импорта (`replaceRaw`, §159/§221)
отбрасывал — на свой же бэкап показывалось «1 unknown keys skipped», настройка
возвращалась к дефолту. Введено §159 (строгий allowlist, 22.06). Фикс: ключ в
`_appFeatureFlagVars` + guard-тест в `backup_service_test.dart`.

### F2 (P2) — refresh выключенной подписки поднимал `configDirty`

`sameComposition`-гейт (§331) не смотрел на `list.enabled`, а билдер
выключенные списки не эмитит — пересборка даёт байт-в-байт тот же конфиг.
С галкой §337 («обновлять выключенные») каждый проход с новым составом давал
ложную синюю плашку «Settings changed». Фикс: `keepDirtyFlag:
sameComposition || !current.enabled` + гейт ручной реакции (`trigger==manual`)
по `enabled` (зеркало гейта `auto_updater`: `compositionChanged &&
fresh.enabled`). Возврат `refreshEntry` остался честным «состав изменился».
Тест — `fetch_dirty_flag_test.dart` кейс `enabled:false`.

### F3 (P3) — single-ping писал замер в канал «на момент завершения»

`runNodeUrltest` брал URL/timeout из `selectedGroup` ДО await, а канал карты
замеров (`_delaysWith` → `_state.delayChannelKey`) резолвился ПОСЛЕ. Смена
канала при висящем пинге (до 10 с) уводила замер, снятый URL'ом канала A, в
карту канала B — от этого же класса mass-ping защитился снимком
`massPingChannel` (§325). Фикс: снимок `delayChannelKey` до await, во все
вызовы `_delaysWith` — `channel: channelKey`.

### F4 (P3) — Debug API `/folders/{id}/probe` отдавал `__vpn_running__`

Внутренний маркер `kProbeVpnRunning` («наружу как сообщение не идёт»,
probe_runner.dart) утекал в ответ `UpstreamError('probe failed to start:
__vpn_running__')`. Фикс: маппинг в `409 Conflict «VPN is running — stop it
before probing»` (UI-путь и так мапит маркер в свой текст).

## Вынесено в отдельную таску (сделано в том же релизе)

- **F5 (P3) — профайлер игнорировал `createdAt`/`closedAt` ядра** для
  short-lived соединений (`duration = 0` + ложный `tcpReset`) →
  [`353`](353-profiler-kernel-timestamps.md).
