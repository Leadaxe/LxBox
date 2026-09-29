[English](route-map.md) · [Русский](route-map.ru.md)

# Карта маршрутов — какой префикс что даёт и какая фича владеет смыслом

На сервере смонтировано двадцать три префикса; каждый зеркалит область
приложения, семантика которой живёт во владеющей фиче, а не здесь.

| Поле | Значение |
|------|----------|
| Фича | [027-DEBUG_API](../FEATURE.ru.md) |
| Обещания | P9 |
| Состояние | ✅ написана по коду, 2026-09-29 |

## Что делает

Превращает путь запроса в обработчик по самому длинному смонтированному
префиксу и говорит читателю, где искать смысл того, что обработчик делает.
Эта таблица — оглавление; полный справочник маршрутов с параметрами, телами и
примерами — [`docs/api/debug-api-reference.md`](../../../../api/debug-api-reference.md)
и собственный `GET /help` сервера — здесь ни то ни другое не дублируется.

## Параметры

Нет: набор префиксов зафиксирован сборкой. Ничего не монтируется условно —
маршрут существует независимо от того, выполнено ли его предусловие (живой
туннель, загруженный интерфейс); в этом случае обработчик отвечает 409.

## Входы / Выходы

**Входы:** путь запроса. **Выходы:** обработчик либо 404 `not_found`.

| Префикс | Что даёт | Владелец семантики |
|---------|----------|--------------------|
| `/ping`, `/help` | проверка жизни; карта возможностей (текст, `?format=json`) — без токена | эта фича — [self-documentation.md](self-documentation.ru.md) |
| `/state` | состояние туннеля и узлов; `/subs`, `/rules`, `/vpn`, `/config_locked`; `/storage` — снимок хранения со скраббером | [012-LIVE_STATE](../../012-LIVE_STATE/FEATURE.ru.md); хранение — [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FUNCTIONS/storage-contract.ru.md) |
| `/device` | версия Android, модель, ABI, версия и сборка приложения, версия ядра, сеть, аптайм | [021-CORE_CONTRACT](../../021-CORE_CONTRACT/FEATURE.ru.md) (версии), [020-APP_SHELL](../../020-APP_SHELL/FEATURE.ru.md) |
| `/config` | сохранённый конфиг сырым или с отступами, его путь, снимок работающего ядра; `PUT` — заменить сохранённый | [019-CONFIG_EDITOR](../../019-CONFIG_EDITOR/FUNCTIONS/config-editor.ru.md), [config-pin.md](../../019-CONFIG_EDITOR/FUNCTIONS/config-pin.ru.md); `/running` — [012-LIVE_STATE](../../012-LIVE_STATE/FUNCTIONS/running-config.ru.md) |
| `/pool` | снимок round-robin-пула по тегу группы | [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FUNCTIONS/balancing.ru.md) |
| `/logs` | журнал приложения и ядра с `limit`, `source`, `q`, `level`; очистка | [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FUNCTIONS/app-log.ru.md), [core-log.md](../../013-DIAGNOSTICS/FUNCTIONS/core-log.ru.md) |
| `/action` | старт, headless-старт, стоп, force-stop, reconnect, reload, reset-network, quic-knobs, urltest, switch-node, set-group, rebuild-config, check-config, refresh-subs, download-srs, clear-srs, toast, emulate-error, check-updates, preview-empty-state | [010-VPN_SERVICE](../../010-VPN_SERVICE/FUNCTIONS/tunnel-control.ru.md), [009-NODE_HEALTH](../../009-NODE_HEALTH/FUNCTIONS/urltest-group.ru.md), [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FUNCTIONS/config-validation.ru.md), [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FUNCTIONS/auto-update.ru.md), [004-ROUTING](../../004-ROUTING/FUNCTIONS/remote-rule-sets.ru.md), [020-APP_SHELL](../../020-APP_SHELL/FUNCTIONS/update-check.ru.md) |
| `/files` | кэш наборов правил, локальные файлы из белого списка, архив отчётов о сбоях, снимки памяти | [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FUNCTIONS/crash-reports.ru.md), [004-ROUTING](../../004-ROUTING/FUNCTIONS/remote-rule-sets.ru.md) |
| `/diag` | дамп, причины завершения, хвост системного журнала, текущий отчёт о сбое, журнал приложения по сессиям, pprof | [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FUNCTIONS/diagnostic-dump.ru.md), [core-profiling.md](../../013-DIAGNOSTICS/FUNCTIONS/core-profiling.ru.md) |
| `/backup` | экспорт снимка данных, импорт со слиянием или заменой | [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FUNCTIONS/full-backup-export.ru.md), [full-backup-restore.md](../../017-BACKUP_AND_STORAGE/FUNCTIONS/full-backup-restore.ru.md) |
| `/rules` | CRUD своих правил, перестановка, перемещение | [004-ROUTING](../../004-ROUTING/FUNCTIONS/inline-rules.ru.md), [rule-order.md](../../004-ROUTING/FUNCTIONS/rule-order.ru.md), [024-TEMPLATE](../../024-TEMPLATE/FUNCTIONS/preset-bundles.ru.md) |
| `/subs` | единый список источников, одна запись с `reveal` / `warnings`, добавление по вводу, патч меты, обновление, перестановка, правила импорта | [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FUNCTIONS/subscription-meta.ru.md), [import-rules.md](../../001-SUBSCRIPTIONS/FUNCTIONS/import-rules.ru.md), [fetch-identity.md](../../001-SUBSCRIPTIONS/FUNCTIONS/fetch-identity.ru.md); разбор — [025-CONTRACT_REGISTRY](../../025-CONTRACT_REGISTRY/FUNCTIONS/parse-warnings.ru.md) |
| `/nodes` | узел как ссылка для обмена — ровно то, что даёт Copy link | [002-NODE_IMPORT](../../002-NODE_IMPORT/FUNCTIONS/share-link-export.ru.md) |
| `/directions` | CRUD Направлений, перестановка, счётчики `healed` | [004-ROUTING](../../026-DIRECTIONS/FUNCTIONS/direction-model.ru.md), [006-DETOUR_AND_BALANCE](../../026-DIRECTIONS/FUNCTIONS/direction-as-detour.ru.md) |
| `/chains` | CRUD цепочек, послойная проба | [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FUNCTIONS/hop-chains.ru.md), [chain-editor.md](../../006-DETOUR_AND_BALANCE/FUNCTIONS/chain-editor.ru.md) |
| `/folders` | папки и их члены по позиции, разгруппировка, перенос, проба | [007-NODE_LIST](../../007-NODE_LIST/FUNCTIONS/server-folders.ru.md), [folder-testing.md](../../007-NODE_LIST/FUNCTIONS/folder-testing.ru.md) |
| `/core_reject` | страховка автовыключения: состояние прогона, сохранённые вердикты, плашка, диалог, отмена, сброс, включение, уведомления по узлу | [009-NODE_HEALTH](../../009-NODE_HEALTH/FUNCTIONS/core-reject-auto-disable.ru.md), [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FUNCTIONS/coded-notifications.ru.md) |
| `/warp` | регистрация узла WARP без интерфейса | [015-WARP](../../015-WARP/FUNCTIONS/one-tap-registration.ru.md) |
| `/settings` | адресные записи: route_final, node_sort, vpn_mode, ping_options, tun_apps, dns_options, vars, config_locked, core_logs_*, vpn/*; алиас rebuild-config | [004-ROUTING](../../004-ROUTING/FEATURE.ru.md), [007-NODE_LIST](../../007-NODE_LIST/FUNCTIONS/node-sorting.ru.md), [010-VPN_SERVICE](../../010-VPN_SERVICE/FUNCTIONS/operating-modes.ru.md), [009-NODE_HEALTH](../../009-NODE_HEALTH/FUNCTIONS/ping-settings.ru.md), [011-SPLIT_TUNNELING](../../011-SPLIT_TUNNELING/FUNCTIONS/mode-and-list.ru.md), [005-DNS](../../005-DNS/FEATURE.ru.md), [024-TEMPLATE](../../024-TEMPLATE/FUNCTIONS/template-language.ru.md), [029-LOCALIZATION](../../029-LOCALIZATION/FUNCTIONS/language-selection.ru.md) |
| `/wifi_history` | сохранённые сети Wi-Fi для условий правил (предел 50) | [004-ROUTING](../../004-ROUTING/FUNCTIONS/wifi-conditions.ru.md) |
| `/profiler` | запись живых событий: старт, стоп, состояние, снимок окна, SSE-поток, кольцо неатрибутированных | [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FUNCTIONS/live-events.ru.md), [028-TRAFFIC_PROFILER](../../028-TRAFFIC_PROFILER/FUNCTIONS/debug-api-access.ru.md) |
| `/support` | состояние ленты поддержки, сброс, предпросмотр одного сообщения | [020-APP_SHELL](../../020-APP_SHELL/FUNCTIONS/support-feed.ru.md) |

## Правила и инварианты

- **Побеждает самый длинный префикс, подстроки не совпадают.**
  `/subs/{id}/rules` — обработчик подписок, `/statex` — не `/state`; путь вне
  всех префиксов — 404 `not_found`. Внутри префикса обработчик сам разбирает
  подпуть и метод: неверный метод — 400, неизвестный подпуть — 404.
- **Чтение — `GET`; каждая запись — `POST`/`PUT`/`PATCH`/`DELETE`** и
  принимает `?rebuild=true` — [write-operations.md](write-operations.ru.md).
- **Идентификаторы и адресация — по области.** Источники по `id`, Направления
  и цепочки по `tag`, члены папок и правила импорта по позиции (индексы
  сдвигаются после удаления или перестановки — следующий индекс брать из
  возвращённого снимка), правила по `id` с разреженной осью `num`.
- **Удалённые префиксы остаются удалёнными.** `/clash/*` и `/state/clash`
  (§122) — 404; алиасов нет.

## Границы

- Смысл поля в ответе области (что значат `healed`, `usable`, `strip_evasion`,
  `warnings[].applied`) — контракт владеющей фичи; карта лишь говорит, где
  искать.
- Подмаршруты, параметры и тела здесь намеренно не перечислены: их несут
  справочник и `/help`, а эта таблица разошлась бы с ними.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---------|--------|------|
| 1 | [031F](../../../tasks/031F-debug-api/spec.md) | ✅ Done → §043 | State, config, журналы, действия, правила, подписки, настройки, файлы |
| 2 | [122F](../../../tasks/122F-commandclient-migration/spec.md) | — | Маршруты Clash API удалены |
| 3 | [035](../../../tasks/035-platform-interface-extras-in-debug-api.md) | ✅ Реализовано (в изменённой форме) | `/diag/*`: причины завершения, системный журнал, дамп |
| 4 | [147](../../../tasks/147-debug-api-warp-endpoint.md) | Implemented | `/warp` |
| 5 | [208](../../../tasks/208-urltest-balancer-round-robin.md) | Реализовано | `/pool` |
| 6 | [238](../../../tasks/238-debug-api-channels-folders.md) | реализовано | `/directions`, `/folders` |
| 7 | [316](../../../tasks/316-kernel-crash-reports-access.md) | Device-verified | `/files/crash`, `/files/oom` |
| 8 | [346](../../../tasks/346-subs-full-crud-debug-api.md) | DEVICE-VERIFIED | `/subs`: мета, identity, правила импорта |
| 9 | [357](../../../tasks/357-support-deeplinks.md) | DEVICE-VERIFIED | `/support` |
| 10 | [478F](../../../tasks/478F-core-rejected-node-auto-disable/spec.md) | Released v2.25.0 | `/core_reject`, `/nodes/link` |
| 11 | [524](../../../tasks/524-unified-source-entries.md) | Released v2.25.3 | `/subs` как единый список с цепочками и `source_key` |
